# Standalone M140 libwebrtc packager for windows-x86_64 / windows-x86.
# Darwin slices: scripts/build-darwin.sh
[CmdletBinding()]
param(
    [string]$Triple = "",
    [string]$Dest = "",
    [string]$Checkout = $env:WEBRTC_CHECKOUT,
    [switch]$DryRun,
    [switch]$SkipFetch,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Get-Content (Join-Path $Root "config\milestone.env") | ForEach-Object {
    $line = ($_ -split "#", 2)[0].Trim()
    if ($line -and $line.Contains("=")) {
        $k, $v = $line.Split("=", 2)
        Set-Variable -Name $k.Trim() -Value $v.Trim() -Scope Script
    }
}

if ($Help) {
    Write-Output @"
Usage: build-windows.ps1 [-Triple windows-x86_64|windows-x86] [-Dest DIR]
                         [-Checkout DIR] [-DryRun] [-SkipFetch] [-Help]

Default triple is this Windows host. Does not build macOS.
Does not download third-party prebuilt webrtc tarballs.
"@
    exit 0
}

if ($env:DRY_RUN -eq "1") { $DryRun = $true }

function Get-CacheRoot {
    if ($env:LIBWEBRTC_ROOT) { return $env:LIBWEBRTC_ROOT }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA "build_libwebrtc") }
    return (Join-Path $HOME ".cache/build_libwebrtc")
}

function Invoke-Plan {
    param([string[]]$Extra)
    $planDest = if ($Dest) { $Dest } else { Join-Path (Join-Path (Get-CacheRoot) $ARTIFACT_TREE) $Triple }
    $py = Join-Path $Root "scripts\render_args.py"
    $args = @($py, "--triple", $Triple, "--dest", $planDest, "--script", "ps1") + $Extra
    $out = & python @args
    if ($LASTEXITCODE -ne 0) { throw "render_args.py failed" }
    return ($out | Select-Object -Last 1)
}

if (-not $Triple) {
    if ($env:PROCESSOR_ARCHITECTURE -eq "x86") { $Triple = "windows-x86" } else { $Triple = "windows-x86_64" }
}

$destOut = Invoke-Plan $(if ($DryRun) { @("--dry-run") } else { @() })
Write-Output "planned $Triple -> $destOut"
if ($DryRun) {
    Write-Output "dry-run: wrote args.gn and BUILD_INFO.json (no fetch/ninja)"
    exit 0
}

$onWindows = ($env:OS -like "*Windows*") -or $IsWindows
if (-not $onWindows) { throw "build-windows.ps1 only runs on Windows" }

$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$retryMax = if ($env:RETRY_MAX) { [int]$env:RETRY_MAX } else { [int]$RETRY_MAX }

function Invoke-Retry {
    param([scriptblock]$Action, [string]$Label)
    $delay = 2
    for ($n = 1; $n -le $retryMax; $n++) {
        & $Action
        if ($LASTEXITCODE -eq 0) { return }
        if ($n -eq $retryMax) { throw "failed after $retryMax tries: $Label" }
        Write-Output "retry $n/$retryMax in ${delay}s: $Label"
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, 45)
    }
}

$cache = Get-CacheRoot
if (-not $Checkout) { $Checkout = Join-Path $cache "checkout" }
$src = Join-Path $Checkout "src"
$depot = if ($env:DEPOT_TOOLS_DIR) { $env:DEPOT_TOOLS_DIR } else { Join-Path $cache "depot_tools" }

if (-not (Test-Path (Join-Path $depot ".git"))) {
    Write-Output "cloning depot_tools -> $depot"
    if (Test-Path $depot) { Remove-Item -Recurse -Force $depot }
    Invoke-Retry -Label "git clone depot_tools" -Action {
        git -c http.version=HTTP/1.1 -c credential.helper= clone --depth=1 $DEPOT_TOOLS_URL $depot
    }
}
$env:PATH = "$depot;$env:PATH"
$bootstrap = Join-Path $depot "ensure_bootstrap.bat"
if (Test-Path $bootstrap) {
    Invoke-Retry -Label "ensure_bootstrap" -Action { & $bootstrap }
}

New-Item -ItemType Directory -Force -Path $Checkout | Out-Null
if (-not $SkipFetch) {
    if (-not (Test-Path (Join-Path $src ".git"))) {
        Write-Output "fetch webrtc (no-history) into $Checkout"
        if (Test-Path $src) { Remove-Item -Recurse -Force $src }
        Invoke-Retry -Label "fetch webrtc" -Action {
            Push-Location $Checkout
            try { fetch --nohooks --no-history webrtc } finally { Pop-Location }
        }
    }
    Invoke-Retry -Label "gclient sync 7339" -Action {
        Push-Location $src
        try {
            git -c http.version=HTTP/1.1 -c credential.helper= fetch --depth=1 origin "+$WEBRTC_REF`:refs/remotes/$WEBRTC_BRANCH"
            if ($LASTEXITCODE -ne 0) { return }
            git checkout -B m140-7339 $WEBRTC_BRANCH
            if ($LASTEXITCODE -ne 0) { return }
            gclient sync -D --no-history
        } finally { Pop-Location }
    }
}

if (-not (Test-Path $src)) { throw "missing $src" }
$commit = git -C $src rev-parse HEAD
$destOut = Invoke-Plan @("--commit", $commit, "--include-path", $src)

$gnOut = Join-Path (Join-Path $src "out") $Triple
New-Item -ItemType Directory -Force -Path $gnOut | Out-Null
Copy-Item (Join-Path $destOut "args.gn") (Join-Path $gnOut "args.gn") -Force
$argsFlat = ((Get-Content (Join-Path $destOut "args.gn")) -join " ")
gn gen $gnOut --args=$argsFlat
if ($env:NINJA_JOBS) { ninja -C $gnOut -j $env:NINJA_JOBS webrtc } else { ninja -C $gnOut webrtc }

$lib = $null
foreach ($cand in @("obj\webrtc.lib", "webrtc.lib", "obj\webrtc\webrtc.lib")) {
    $p = Join-Path $gnOut $cand
    if (Test-Path $p) { $lib = $p; break }
}
if (-not $lib) { throw "webrtc.lib not found under $gnOut" }
$libDir = Join-Path $destOut "lib"
$incDir = Join-Path $destOut "include"
New-Item -ItemType Directory -Force -Path $libDir, $incDir | Out-Null
Copy-Item $lib (Join-Path $libDir "webrtc.lib") -Force
Get-ChildItem -Path $src -Recurse -Include *.h, *.hpp, *.inc | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart("\", "/")
    if ($rel -like "out\*" -or $rel -like ".git\*") { return }
    $target = Join-Path $incDir $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item $_.FullName $target -Force
}

Write-Output "ok $Triple"
Write-Output "  LIBWEBRTC_INCLUDE_PATH=$incDir"
Write-Output "  LIBWEBRTC_BINARY_PATH=$libDir"
