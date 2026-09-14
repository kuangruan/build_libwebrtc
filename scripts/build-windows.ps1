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
# depot_tools often sets GIT_CONFIG_NOSYSTEM and ignores user gitconfig.
# GIT_CONFIG_* env still applies to child `git reset` in third_party.
function Add-GitConfigEnv([string]$Key, [string]$Value) {
    $n = 0
    if ($env:GIT_CONFIG_COUNT) { $n = [int]$env:GIT_CONFIG_COUNT }
    Set-Item -Path "env:GIT_CONFIG_KEY_$n" -Value $Key
    Set-Item -Path "env:GIT_CONFIG_VALUE_$n" -Value $Value
    $env:GIT_CONFIG_COUNT = "$($n + 1)"
}
Add-GitConfigEnv "core.longpaths" "true"
Add-GitConfigEnv "core.autocrlf" "false"
Add-GitConfigEnv "core.filemode" "false"
# depot_tools reads %USERPROFILE%\.gitconfig; Actions images may not have one.
# Uncommitted third_party dirt is usually CRLF from the default autocrlf.
$gitconfig = Join-Path $env:USERPROFILE ".gitconfig"
if (-not (Test-Path $gitconfig)) {
    @"
[core]
	autocrlf = false
	filemode = false
	longpaths = true
[depot-tools]
	allowGlobalGitConfig = false
"@ | Set-Content -Path $gitconfig -Encoding Ascii
}
git config --global core.autocrlf false
git config --global core.filemode false
git config --global core.longpaths true
git config --global depot-tools.allowGlobalGitConfig false
try { git config --system core.longpaths true } catch { }
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -Type DWord -Force
} catch { }
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
if (-not $Checkout) {
    # LOCALAPPDATA\build_libwebrtc\checkout\src\third_party\blink\web_tests\... > MAX_PATH.
    if ($env:GITHUB_ACTIONS) { $Checkout = "C:\w" } else { $Checkout = Join-Path $cache "checkout" }
}
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
            $tp = Join-Path $src "third_party"
            if (Test-Path (Join-Path $tp ".git")) {
                git -c core.longpaths=true -C $tp reset --hard HEAD
                if ($LASTEXITCODE -ne 0) {
                    Write-Output "third_party reset failed (long path); wiping $tp"
                    Remove-Item -Recurse -Force $tp
                } else {
                    git -c core.longpaths=true -C $tp clean -ffd
                }
            }
            gclient sync -D --reset --force --no-history
        } finally { Pop-Location }
    }
}

if (-not (Test-Path $src)) { throw "missing $src" }
$commit = git -C $src rev-parse HEAD
$destOut = Invoke-Plan @("--commit", $commit, "--include-path", $src)

$gnOut = Join-Path (Join-Path $src "out") $Triple
New-Item -ItemType Directory -Force -Path $gnOut | Out-Null
Copy-Item (Join-Path $destOut "args.gn") (Join-Path $gnOut "args.gn") -Force
if (-not (Test-Path (Join-Path $src ".gn"))) {
    throw "missing $src\.gn (gclient sync incomplete)"
}
$expectCpu = if ($Triple -eq "windows-x86") { "x86" } else { "x64" }
$argsFlat = & python (Join-Path $Root "scripts\render_args.py") --flatten (Join-Path $destOut "args.gn")
if ($LASTEXITCODE -ne 0) { throw "flatten args.gn failed" }
Write-Output "gn --args=$argsFlat"
# depot_tools' gn is a wrapper; gn.py requires a second real gn.exe on PATH
# (CIPD binary under src\buildtools\win).
function Ensure-Gn {
    $cands = @(
        (Join-Path $src "buildtools\win\gn.exe"),
        (Join-Path $src "buildtools\win\gn"),
        (Join-Path $src "third_party\gn\gn.exe"),
        (Join-Path $src "third_party\depot_tools\gn.exe")
    )
    $bin = $null
    foreach ($c in $cands) {
        if (Test-Path $c) { $bin = (Resolve-Path $c).Path; break }
    }
    if (-not $bin) {
        $hit = Get-ChildItem -Path @(
            (Join-Path $src "buildtools"),
            (Join-Path $src "third_party")
        ) -Recurse -Filter "gn.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\depot_tools\\gn.exe$' } |
            Select-Object -First 1
        if ($hit) { $bin = $hit.FullName }
    }
    if (-not $bin) {
        throw "real gn.exe not found (depot_tools wrapper alone is not enough)"
    }
    $env:PATH = "$(Split-Path -Parent $bin);$depot;$env:PATH"
    # Write-Host / Out-Host: Write-Output and native stdout become the
    # function return value, so `$gnBin = Ensure-Gn` would be
    # "using gn C:\w\...\gn.exe 2265 (...) C:\w\...\gn.exe".
    Write-Host "using gn $bin"
    & $bin --version | Out-Host
    return $bin
}
$gnBin = Ensure-Gn | Select-Object -Last 1
if (-not (Test-Path -LiteralPath $gnBin)) {
    throw "Ensure-Gn did not return gn.exe: $gnBin"
}
# Real gn walks cwd for .gn. Actions cwd is this repo, not the WebRTC tree.
# Quote --args so PowerShell does not split target_os="win".
& $gnBin --root=$src gen $gnOut "--args=$argsFlat"
if ($LASTEXITCODE -ne 0) { throw "gn gen failed" }
$gotCpu = (& $gnBin --root=$src args $gnOut --list=target_cpu --short 2>$null | Out-String)
if ($gotCpu -match '"([^"]+)"') {
    $gotCpu = $Matches[1]
} else {
    $listed = & $gnBin --root=$src args $gnOut --list=target_cpu
    $gotCpu = [regex]::Match(($listed | Out-String), '"([^"]+)"').Groups[1].Value
}
if ($gotCpu -ne $expectCpu) {
    throw "gn target_cpu=$gotCpu want $expectCpu for $Triple"
}
if ($env:NINJA_JOBS) { ninja -C $gnOut -j $env:NINJA_JOBS webrtc api:field_trials } else { ninja -C $gnOut webrtc api:field_trials }

$lib = $null
foreach ($cand in @("obj\webrtc.lib", "webrtc.lib", "obj\webrtc\webrtc.lib")) {
    $p = Join-Path $gnOut $cand
    if (Test-Path $p) { $lib = $p; break }
}
if (-not $lib) { throw "webrtc.lib not found under $gnOut" }
$ft = $null
foreach ($cand in @("obj\api\field_trials.obj", "obj\api\field_trials\field_trials.obj", "obj\api\field_trials.lib")) {
    $p = Join-Path $gnOut $cand
    if (Test-Path $p) { $ft = $p; break }
}
if (-not $ft) {
    $hit = Get-ChildItem -Path (Join-Path $gnOut "obj\api") -Recurse -Include "field_trials.obj","field_trials.lib" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $ft = $hit.FullName }
}
if (-not $ft) { throw "api:field_trials output not found under $gnOut" }
$libDir = Join-Path $destOut "lib"
$incDir = Join-Path $destOut "include"
New-Item -ItemType Directory -Force -Path $libDir, $incDir | Out-Null
$outLib = Join-Path $libDir "webrtc.lib"
# `webrtc` complete_static_lib does not include embedder-only FieldTrials::Create.
if (Get-Command lib.exe -ErrorAction SilentlyContinue) {
    & lib.exe "/OUT:$outLib" $lib $ft
    if ($LASTEXITCODE -ne 0) { throw "lib.exe failed merging api:field_trials" }
} elseif (Get-Command llvm-lib -ErrorAction SilentlyContinue) {
    & llvm-lib "/OUT:$outLib" $lib $ft
    if ($LASTEXITCODE -ne 0) { throw "llvm-lib failed merging api:field_trials" }
} else {
    throw "need lib.exe or llvm-lib to merge api:field_trials into webrtc.lib"
}
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
