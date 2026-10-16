#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/render_args.py"
SH="$ROOT/scripts/build-darwin.sh"
LSH="$ROOT/scripts/build-linux.sh"
PS1="$ROOT/scripts/build-windows.ps1"
WF="$ROOT/.github/workflows/build.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

list="$(python3 "$PY" --list | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "$list" == "darwin-arm64 darwin-x86_64 linux-arm64 windows-x86_64 windows-x86" ]] || fail "triples: $list"

dest="$TMP/darwin-arm64"
python3 "$PY" --triple darwin-arm64 --dest "$dest" --script sh --dry-run >/dev/null
[[ -f "$dest/args.gn" ]] || fail "missing args.gn"
grep -q 'rtc_use_h264=false' "$dest/args.gn" || fail "missing h264=false"
grep -q 'target_os="mac"' "$dest/args.gn" || fail "missing target_os"
grep -q 'target_cpu="arm64"' "$dest/args.gn" || fail "missing arm64"
if grep -q 'rtc_use_h264=true' "$dest/args.gn"; then fail "h264 true leaked"; fi

if python3 "$PY" --triple linux-x86_64 --dest "$TMP/bad" --script sh --dry-run 2>"$TMP/err"; then
  fail "linux-x86_64 is not a triple we build"
fi
grep -q 'unknown triple' "$TMP/err" || fail "unknown triple message"

# linux-arm64 renders through the same sh path as darwin (it is a POSIX host).
linux_dest="$TMP/linux-arm64"
python3 "$PY" --triple linux-arm64 --dest "$linux_dest" --script sh --dry-run >/dev/null
grep -q 'target_os="linux"' "$linux_dest/args.gn" || fail "missing target_os linux"
grep -q 'target_cpu="arm64"' "$linux_dest/args.gn" || fail "linux-arm64 cpu"
grep -q 'rtc_use_h264=false' "$linux_dest/args.gn" || fail "linux missing h264=false"
linux_flat="$(python3 "$PY" --flatten "$linux_dest/args.gn")"
echo "$linux_flat" | grep -q 'target_cpu="arm64"' || fail "flatten dropped linux arm64"

bash "$LSH" --dry-run --triple linux-arm64 --dest "$TMP/lin-slice" >/dev/null
grep -q 'target_os="linux"' "$TMP/lin-slice/args.gn" || fail "build-linux dry-run missing target_os"
# The default triple is the one it exists for.
bash "$LSH" --dry-run --dest "$TMP/lin-default" >/dev/null
grep -q 'target_cpu="arm64"' "$TMP/lin-default/args.gn" || fail "build-linux default triple"
for other in darwin-arm64 windows-x86_64; do
  if bash "$LSH" --dry-run --triple "$other" --dest "$TMP/wrong" >/dev/null 2>"$TMP/lserr"; then
    fail "build-linux must refuse $other"
  fi
  grep -q 'only builds linux-arm64' "$TMP/lserr" || fail "build-linux refusal message for $other"
done

if python3 "$PY" --triple windows-x86_64 --dest "$TMP/win" --script sh --dry-run 2>"$TMP/err2"; then
  fail "windows via sh should be rejected"
fi
grep -q 'build-windows.ps1' "$TMP/err2" || fail "windows redirected to ps1"

bash "$SH" --dry-run --triple darwin-x86_64 --dest "$TMP/slice" >/dev/null
grep -q 'target_cpu="x64"' "$TMP/slice/args.gn" || fail "darwin-x86_64 cpu"
flat="$(python3 "$PY" --flatten "$TMP/slice/args.gn")"
echo "$flat" | grep -q '#' && fail "flatten leaked a comment (gn --args would drop target_cpu)"
echo "$flat" | grep -q 'target_cpu="x64"' || fail "flatten dropped x64"
echo "$flat" | grep -q 'rtc_use_h264=false' || fail "flatten dropped h264=false"

arm_dest="$TMP/darwin-arm64-flat"
python3 "$PY" --triple darwin-arm64 --dest "$arm_dest" --script sh --dry-run >/dev/null
arm_flat="$(python3 "$PY" --flatten "$arm_dest/args.gn")"
echo "$arm_flat" | grep -q 'target_cpu="arm64"' || fail "flatten dropped arm64"

short_arm='target_cpu = "arm64"'
parsed="$(printf '%s\n' "$short_arm" | python3 "$PY" --parse-gn-value)"
[[ "$parsed" == "arm64" ]] || fail "parse --short arm64 got $parsed"
# The old tr -d ' \"' path turned this into target_cpu=arm64 and failed the check.
stripped="$(printf '%s\n' "$short_arm" | tr -d ' \"')"
[[ "$stripped" == "target_cpu=arm64" ]] || fail "fixture for the tr bug drifted: $stripped"
[[ "$parsed" != "$stripped" ]] || fail "parser must not return the tr-stripped line"
long_arm=$'target_cpu\n    Current value = "arm64"\n      From //out/darwin-arm64/args.gn:13'
parsed="$(printf '%s\n' "$long_arm" | python3 "$PY" --parse-gn-value)"
[[ "$parsed" == "arm64" ]] || fail "parse long listing arm64 got $parsed"
parsed="$(printf '%s\n' 'target_cpu = "x64"' | python3 "$PY" --parse-gn-value)"
[[ "$parsed" == "x64" ]] || fail "parse --short x64 got $parsed"

if bash "$SH" --dry-run --triple windows-x86_64 --dest "$TMP/nope" >/dev/null 2>"$TMP/err3"; then
  fail "sh must reject windows"
fi

body_sh="$(cat "$SH")"
body_lsh="$(cat "$LSH")"
body_ps="$(cat "$PS1")"
for body in "$body_sh" "$body_ps"; do
  echo "$body" | grep -q 'fetch --nohooks --no-history webrtc' || fail "missing no-history fetch"
  echo "$body" | grep -q 'gclient sync -D' || fail "missing gclient sync -D"
  echo "$body" | grep -q -- '--no-history' || fail "missing no-history sync"
  echo "$body" | grep -q 'fetch --depth=1' || fail "missing depth=1"
done
# linux builds its own checkout (no `fetch`) so it can drop the one cipd entry
# that has no arm64 package; the same contract applies, differently spelled.
echo "$body_lsh" | grep -q 'gclient sync -D --no-history' || fail "linux missing gclient sync -D --no-history"
echo "$body_lsh" | grep -q 'fetch --depth=1' || fail "linux missing depth=1 fetch"
if echo "$body_lsh" | grep -q 'fetch --nohooks --no-history webrtc'; then
  fail "linux must not use fetch: it syncs before the jdk entry can be dropped"
fi
echo "$body_lsh" | grep -q '"src/third_party/jdk": None' || fail "linux must drop the linux-arm64-less jdk cipd package"
echo "$body_lsh" | grep -q 'custom_deps' || fail "linux must drop it through custom_deps"
echo "$body_ps" | grep -q 'windows-x86_64' || fail "ps1 missing x64"
echo "$body_ps" | grep -q 'windows-x86' || fail "ps1 missing x86"
echo "$body_sh" | grep -q 'gn --root="$SRC"' || fail "darwin gn must pass --root (Actions cwd has no .gn)"
echo "$body_sh" | grep -q -- '--flatten' || fail "darwin must flatten args.gn (leading # swallows target_cpu)"
echo "$body_sh" | grep -q -- '--parse-gn-value' || fail "darwin must parse gn --short quoted value"
echo "$body_sh" | grep -q "tr -d ' \\\"'" && fail "darwin must not tr-strip gn --short (leaves target_cpu=arm64)"
echo "$body_sh" | grep -q 'macos-15-intel' || fail "darwin-x86_64 must refuse Apple Silicon hosts"
echo "$body_sh" | grep -q 'api:field_trials' || fail "darwin must ninja api:field_trials (FieldTrials::Create)"
echo "$body_sh" | grep -q 'FieldTrials::Create' || fail "darwin must nm-check FieldTrials::Create"
echo "$body_ps" | grep -q 'api:field_trials' || fail "windows must ninja api:field_trials"

# linux-arm64: the same contract as darwin (POSIX host, same flatten/parse rules),
# plus the two things only this slice has: the type of the host it runs on, and an
# arch check that is not lipo.
echo "$body_lsh" | grep -q 'gn --root="$SRC"' || fail "linux gn must pass --root (Actions cwd has no .gn)"
echo "$body_lsh" | grep -q -- '--flatten' || fail "linux must flatten args.gn (leading # swallows target_cpu)"
echo "$body_lsh" | grep -q -- '--parse-gn-value' || fail "linux must parse gn --short quoted value"
echo "$body_lsh" | grep -q "tr -d ' \\\"'" && fail "linux must not tr-strip gn --short (leaves target_cpu=arm64)"
echo "$body_lsh" | grep -q 'api:field_trials' || fail "linux must ninja api:field_trials"
echo "$body_lsh" | grep -q 'FieldTrials::Create' || fail "linux must nm-check FieldTrials::Create"
echo "$body_lsh" | grep -q 'linux64/gn' || fail "linux must find the CIPD gn under buildtools/linux64"
echo "$body_lsh" | grep -q 'uname -s' || fail "linux must refuse non-Linux hosts"
echo "$body_lsh" | grep -q 'use_sysroot=true' || fail "linux cross path must add use_sysroot (x86_64 host)"
echo "$body_lsh" | grep -q 'install-sysroot.py" --arch=arm64' ||
  fail "linux cross path must fetch the arm64 sysroot (gn asserts without it)"
echo "$body_lsh" | grep -q 'aarch64' || fail "linux must check the archive is aarch64, not just that it built"
echo "$body_lsh" | grep -q 'all \$total members are' ||
  fail "linux must walk every archive member: sampling one lets a mixed slice ship"
echo "$body_lsh" | grep -q 'arguments changed for' ||
  fail "linux must wipe a build directory whose arguments changed (stale objects)"
echo "$body_lsh" | grep -q 'file "$OBJ_PROBE/probe.o"' || fail "linux must arch-check a real member with file(1)"
if echo "$body_lsh" | grep -qE '(^|[^[:alnum:]_])lipo[[:space:]]+-info'; then
  fail "linux has no lipo; the arch check must be file/ar based"
fi
echo "$body_lsh" | grep -q 'only builds linux-arm64' || fail "linux must refuse the other triples"
echo "$body_sh" | grep -q 'lipo -info' || fail "darwin must lipo-check the archive arch"
echo "$body_sh" | grep -q 'Architectures in the fat file' || fail "darwin fat check must not match Non-fat file"
thin_info='Non-fat file: /Users/runner/.cache/build_libwebrtc/m140-7339/darwin-arm64/lib/libwebrtc.a is architecture: arm64'
if echo "$thin_info" | grep -Eiq 'Architectures in the fat file'; then
  fail "thin lipo -info must not be treated as fat"
fi
fat_info='Architectures in the fat file: /tmp/libwebrtc.a are: x86_64 arm64'
if ! echo "$fat_info" | grep -Eiq 'Architectures in the fat file'; then
  fail "fat lipo -info must still be rejected"
fi
echo "$body_ps" | grep -q 'Ensure-Gn' || fail "windows must find real gn.exe (depot_tools wrapper is not enough)"
if echo "$body_ps" | grep -q 'Write-Output "using gn'; then
  fail "Ensure-Gn Write-Output pollutes \$gnBin (PowerShell captures all pipeline output)"
fi
echo "$body_ps" | grep -q 'Write-Host "using gn' || fail "Ensure-Gn must Write-Host the real gn.exe"
echo "$body_ps" | grep -q 'Out-Host' || fail "Ensure-Gn must not leave gn --version on the success pipeline"
echo "$body_ps" | grep -q 'Select-Object -Last 1' || fail "windows must take last Ensure-Gn output as gn.exe"
echo "$body_ps" | grep -q -- '--root=$src' || fail "windows gn must pass --root (Actions cwd has no .gn)"
echo "$body_ps" | grep -q -- '--flatten' || fail "windows must flatten args.gn"
echo "$body_ps" | grep -q '"--args=$argsFlat"' || fail "windows must quote gn --args"
echo "$body_ps" | grep -q 'buildtools\\win\\gn.exe' || fail "windows must look for CIPD gn.exe"
echo "$body_ps" | grep -q 'core.longpaths' || fail "windows must enable git longpaths"
echo "$body_ps" | grep -Fq 'C:\w' || fail "windows Actions checkout must be a short path"
grep -q 'WEBRTC_CHECKOUT' "$WF" || fail "workflow must set a short Windows checkout"
grep -q 'gh release create' "$WF" || fail "workflow must publish successful slices to Releases"
grep -q 'macos-15-intel' "$WF" || fail "workflow must run darwin-x86_64 on Intel, not macos-15"
if awk '/darwin:/{d=1} d && /runs-on: macos-15$/{bad=1} d && /windows:/{d=0} END{exit !bad}' "$WF"; then
  fail "workflow must not run every Darwin triple on macos-15"
fi
# linux-arm64 is cross-compiled on an x86_64 runner: the clang cipd ships for
# linux is x86_64 (a native arm64 build fails with "Exec format error"), and its
# arm64 sysroot is what --target=aarch64-linux-gnu needs. Its slice still has to
# reach the release.
grep -q 'os: ubuntu-24.04$' "$WF" || fail "workflow must build linux-arm64 on an x86_64 runner"
if grep -q 'ubuntu-24.04-arm' "$WF"; then
  fail "workflow must not use the arm64 runner: its cipd clang is x86_64"
fi
grep -qE '^\s+- linux-arm64$' "$WF" || fail "workflow dispatch must offer linux-arm64"
# Nothing gets published unverified: a Mach-O archive shipped once under a
# linux-arm64 asset and only failed at a consumer's linker, which is far too late
# to be the first time anyone looks.
grep -q 'name: verify' "$WF" || fail "workflow must verify a slice before packing it"
grep -q 'refusing to publish it' "$WF" || fail "linux verify must refuse a non-ELF archive"
grep -q 'ELF 64-bit.\*aarch64' "$WF" || fail "linux verify must check every member's architecture"
grep -q 'lipo -info' "$WF" || fail "darwin verify must check the archive with lipo"
if ! awk '/^  release:/{r=1} r && /needs:/{print; exit}' "$WF" | grep -q 'linux'; then
  fail "workflow release must depend on the linux job"
fi
if ! awk '/^  release:/{r=1} r && /needs\.linux\.result/{found=1} END{exit !found}' "$WF"; then
  fail "release notes must say when the linux jobs failed"
fi

for t in darwin-arm64 darwin-x86_64 linux-arm64 windows-x86_64 windows-x86; do
  grep -q "$t" "$WF" || fail "workflow missing $t"
done

echo "ok test_plan"
