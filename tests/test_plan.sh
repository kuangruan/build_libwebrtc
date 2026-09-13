#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/render_args.py"
SH="$ROOT/scripts/build-darwin.sh"
PS1="$ROOT/scripts/build-windows.ps1"
WF="$ROOT/.github/workflows/build.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

list="$(python3 "$PY" --list | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "$list" == "darwin-arm64 darwin-x86_64 windows-x86_64 windows-x86" ]] || fail "triples: $list"

dest="$TMP/darwin-arm64"
python3 "$PY" --triple darwin-arm64 --dest "$dest" --script sh --dry-run >/dev/null
[[ -f "$dest/args.gn" ]] || fail "missing args.gn"
grep -q 'rtc_use_h264=false' "$dest/args.gn" || fail "missing h264=false"
grep -q 'target_os="mac"' "$dest/args.gn" || fail "missing target_os"
grep -q 'target_cpu="arm64"' "$dest/args.gn" || fail "missing arm64"
if grep -q 'rtc_use_h264=true' "$dest/args.gn"; then fail "h264 true leaked"; fi

if python3 "$PY" --triple linux-x86_64 --dest "$TMP/bad" --script sh --dry-run 2>"$TMP/err"; then
  fail "linux should be rejected"
fi
grep -q 'unknown triple' "$TMP/err" || fail "unknown triple message"

if python3 "$PY" --triple windows-x86_64 --dest "$TMP/win" --script sh --dry-run 2>"$TMP/err2"; then
  fail "windows via sh should be rejected"
fi
grep -q 'build-windows.ps1' "$TMP/err2" || fail "windows redirected to ps1"

bash "$SH" --dry-run --triple darwin-x86_64 --dest "$TMP/slice" >/dev/null
grep -q 'target_cpu="x64"' "$TMP/slice/args.gn" || fail "darwin-x86_64 cpu"

if bash "$SH" --dry-run --triple windows-x86_64 --dest "$TMP/nope" >/dev/null 2>"$TMP/err3"; then
  fail "sh must reject windows"
fi

body_sh="$(cat "$SH")"
body_ps="$(cat "$PS1")"
for body in "$body_sh" "$body_ps"; do
  echo "$body" | grep -q 'fetch --nohooks --no-history webrtc' || fail "missing no-history fetch"
  echo "$body" | grep -q 'gclient sync -D --no-history' || fail "missing no-history sync"
  echo "$body" | grep -q 'fetch --depth=1' || fail "missing depth=1"
done
echo "$body_ps" | grep -q 'windows-x86_64' || fail "ps1 missing x64"
echo "$body_ps" | grep -q 'windows-x86' || fail "ps1 missing x86"

for t in darwin-arm64 darwin-x86_64 windows-x86_64 windows-x86; do
  grep -q "$t" "$WF" || fail "workflow missing $t"
done

echo "ok test_plan"
