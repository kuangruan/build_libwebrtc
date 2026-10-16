#!/usr/bin/env bash
# Standalone M140 libwebrtc packager for linux-arm64.
# Darwin slices: scripts/build-darwin.sh   Windows slices: scripts/build-windows.ps1
#
# Native on an arm64 Linux host (the ubuntu-24.04-arm runner build.yml uses).
# Also cross-builds from x86_64 Linux by adding use_sysroot=true, which makes
# depot_tools fetch the arm64 sysroot; that path is slower and untested in CI,
# so the workflow runs it natively.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/milestone.env"

TRIPLE=""
DEST=""
CHECKOUT="${WEBRTC_CHECKOUT:-}"
DRY_RUN=0
SKIP_FETCH=0
CROSS=""          # "", "auto" (native if possible), "always"

usage() {
  cat <<'EOF'
Usage: build-linux.sh [--triple linux-arm64] [--dest DIR] [--checkout DIR]
                      [--cross auto|always] [--dry-run] [--skip-fetch] [--help]

Default triple is linux-arm64, and the build is native when the host is arm64.
--cross=always adds use_sysroot=true so an x86_64 host can build it too.
Does not build Darwin or Windows.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --triple)
      TRIPLE="${2:?}"
      shift 2
      ;;
    --dest)
      DEST="${2:?}"
      shift 2
      ;;
    --checkout)
      CHECKOUT="${2:?}"
      shift 2
      ;;
    --cross)
      CROSS="${2:?}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-fetch)
      SKIP_FETCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TRIPLE" ]]; then
  TRIPLE=linux-arm64
fi
if [[ "$TRIPLE" != "linux-arm64" ]]; then
  echo "error: build-linux.sh only builds linux-arm64 (got $TRIPLE)" >&2
  case "$TRIPLE" in
    darwin-*) echo "       use scripts/build-darwin.sh" >&2 ;;
    windows-*) echo "       use scripts/build-windows.ps1" >&2 ;;
  esac
  exit 1
fi

CACHE="${LIBWEBRTC_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/build_libwebrtc}"
if [[ -z "$DEST" ]]; then
  DEST="$CACHE/$ARTIFACT_TREE/$TRIPLE"
fi

plan() {
  local dest="$1"
  shift
  python3 "$ROOT/scripts/render_args.py" --triple "$TRIPLE" --dest "$dest" --script sh "$@"
}

DEST="$(plan "$DEST" $( [[ $DRY_RUN -eq 1 ]] && printf '%s' '--dry-run' ))"
echo "planned $TRIPLE -> $DEST"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "dry-run: wrote args.gn and BUILD_INFO.json (no fetch/ninja)"
  exit 0
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: build-linux.sh only runs on Linux" >&2
  exit 1
fi

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64) HOST_ARCH=arm64 ;;
  x86_64|amd64) HOST_ARCH=x86_64 ;;
esac
EXPECT_CPU=arm64
EXPECT_FILE=aarch64

if [[ "$CROSS" == "always" || "$HOST_ARCH" != "arm64" ]]; then
  SYSROOT_ARGS='use_sysroot=true'
  echo "host $HOST_ARCH building $TRIPLE (cross: $SYSROOT_ARGS)"
else
  SYSROOT_ARGS=''
  echo "host $HOST_ARCH building $TRIPLE (native)"
fi

retry() {
  local n=1 delay=2
  while true; do
    if "$@"; then
      return 0
    fi
    if [[ $n -ge ${RETRY_MAX:-8} ]]; then
      echo "error: failed after $RETRY_MAX tries: $*" >&2
      return 1
    fi
    echo "retry $n/$RETRY_MAX in ${delay}s: $*" >&2
    sleep "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
    if [[ $delay -gt 45 ]]; then
      delay=45
    fi
  done
}

git_http() {
  git -c http.version=HTTP/1.1 -c credential.helper= "$@"
}

if [[ -z "$CHECKOUT" ]]; then
  CHECKOUT="$CACHE/checkout"
fi
SRC="$CHECKOUT/src"
DEPOT="${DEPOT_TOOLS_DIR:-$CACHE/depot_tools}"

if [[ ! -d "$DEPOT/.git" ]]; then
  echo "cloning depot_tools -> $DEPOT"
  rm -rf "$DEPOT"
  retry git_http clone --depth=1 "$DEPOT_TOOLS_URL" "$DEPOT"
fi
export PATH="$DEPOT:$PATH"

CURL_WRAP="$CACHE/curl-retry-bin"
mkdir -p "$CURL_WRAP"
REAL_CURL="$(command -v curl)"
if [[ "$REAL_CURL" == "$CURL_WRAP/curl" ]]; then
  REAL_CURL=/usr/bin/curl
fi
cat >"$CURL_WRAP/curl" <<EOF
#!/bin/bash
exec "${REAL_CURL}" --retry 8 --retry-delay 2 --retry-all-errors "\$@"
EOF
chmod +x "$CURL_WRAP/curl"
export PATH="$CURL_WRAP:$PATH"

if [[ -x "$DEPOT/ensure_bootstrap" ]]; then
  retry "$DEPOT/ensure_bootstrap"
fi

mkdir -p "$CHECKOUT"
if [[ $SKIP_FETCH -eq 0 ]]; then
  # Not `fetch`: it syncs the moment it runs, and this host has to drop one
  # entry from that very first sync -- chromium/third_party/jdk has no
  # linux-arm64 package (Google publishes the JDK for amd64, mac and windows
  # only; arm64 Linux is expected to use a distro JDK), and a package cipd
  # cannot resolve fails the whole sync before a single object is compiled.
  # Chromium's own DEPS drops reclient for the same reason on this platform.
  #
  # fetch also cannot be retried over its own partial state ("Your current
  # directory appears to already contain ... a checkout"): doing the four steps
  # here keeps retries meaningful, and gclient sync resumes a partial tree.
  WEBRTC_URL="https://webrtc.googlesource.com/src.git"
  if [[ ! -d "$SRC/.git" ]]; then
    echo "fetch webrtc (no-history) into $CHECKOUT"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    retry git_http -C "$SRC" init -q
    retry git_http -C "$SRC" remote add origin "$WEBRTC_URL" 2>/dev/null || true
  fi
  retry bash -c '
    set -euo pipefail
    cd "$1"
    git -c http.version=HTTP/1.1 -c credential.helper= fetch --depth=1 origin "+'"$WEBRTC_REF"':refs/remotes/'"$WEBRTC_BRANCH"'"
    git checkout -B m140-7339 '"$WEBRTC_BRANCH"'
  ' _ "$SRC"
  # Unquoted heredoc on purpose: WEBRTC_URL is expanded here, and the rest of
  # the file has no $ at all.
  cat >"$CHECKOUT/.gclient" <<EOF
# Generated by build-linux.sh. custom_deps is the arm64 Linux fix, not a
# preference: see the comment in the script.
solutions = [
  {
    "name": "src",
    "url": "$WEBRTC_URL",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {
      "src/third_party/jdk": None,
    },
    "custom_vars": {},
  },
]
EOF
  retry bash -c 'cd "$1" && gclient sync -D --no-history' _ "$SRC"
fi

if [[ ! -d "$SRC" ]]; then
  echo "error: missing $SRC" >&2
  exit 1
fi

COMMIT="$(git -C "$SRC" rev-parse HEAD)"
DEST="$(plan "$DEST" --commit "$COMMIT" --include-path "$SRC")"

# depot_tools' gn is a wrapper; gn.py requires a second real `gn` on PATH
# (CIPD binary under src/buildtools/linux64).
ensure_gn() {
  local bin="" cand
  for cand in \
    "$SRC/buildtools/linux64/gn" \
    "$SRC/third_party/gn/gn"; do
    if [[ -x "$cand" ]]; then
      bin="$cand"
      break
    fi
  done
  if [[ -z "$bin" ]]; then
    bin="$(find "$SRC/buildtools" "$SRC/third_party" "$DEPOT" \
      -type f -name gn ! -path '*/depot_tools/gn' 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    echo "error: real gn binary not found (depot_tools wrapper alone is not enough)" >&2
    echo "PATH=$PATH" >&2
    ls -la "$SRC/buildtools/linux64" 2>/dev/null || true
    return 1
  fi
  export PATH="$(dirname "$bin"):$DEPOT:$PATH"
  hash -r || true
  echo "using gn $bin"
  gn --version
}

ensure_gn

if [[ -n "$SYSROOT_ARGS" ]]; then
  # gclient's hook fetches only the *host's* sysroot, so a cross build starts
  # without the target's and gn stops at its own assertion:
  #   Missing sysroot (//build/linux/debian_bullseye_arm64-sysroot).
  #   To fix, run: build/linux/sysroot_scripts/install-sysroot.py --arch=arm64
  # That script is what this is, and it is idempotent when the sysroot is there.
  retry python3 "$SRC/build/linux/sysroot_scripts/install-sysroot.py" --arch=arm64
fi

GN_OUT="$SRC/out/$TRIPLE"
# A build directory remembers the architecture it was configured for, and reusing
# one across a target_cpu change is how objects from two architectures end up in
# one archive. Wipe it when the arguments differ from what is being asked now.
if [[ -f "$GN_OUT/args.gn" ]] && ! diff -q "$DEST/args.gn" "$GN_OUT/args.gn" >/dev/null 2>&1; then
  echo "==> arguments changed for $TRIPLE; wiping $GN_OUT"
  rm -rf "$GN_OUT"
fi
mkdir -p "$GN_OUT"
cp "$DEST/args.gn" "$GN_OUT/args.gn"
if [[ -n "$SYSROOT_ARGS" ]]; then
  # Not part of the frozen arg set (it is a host-side property of this run), so
  # it is appended here rather than in args.gn: the same triple built natively
  # must not carry it.
  printf '%s\n' "$SYSROOT_ARGS" >>"$GN_OUT/args.gn"
fi
if [[ ! -f "$SRC/.gn" ]]; then
  echo "error: missing $SRC/.gn (gclient sync incomplete)" >&2
  exit 1
fi
# Real gn walks cwd for .gn. Actions cwd is this repo, not the WebRTC tree.
# Do not flatten args.gn with `tr` — a leading `#` comment would swallow target_cpu.
GN_ARGS="$(python3 "$ROOT/scripts/render_args.py" --flatten "$GN_OUT/args.gn")"
echo "gn --args=$GN_ARGS"
gn --root="$SRC" gen "$GN_OUT" --args="$GN_ARGS"
# gn --short prints `target_cpu = "arm64"`. Take the quoted cpu, not the whole line.
GOT_CPU="$(gn --root="$SRC" args "$GN_OUT" --list=target_cpu --short 2>/dev/null | python3 "$ROOT/scripts/render_args.py" --parse-gn-value || true)"
if [[ -z "$GOT_CPU" ]]; then
  GOT_CPU="$(gn --root="$SRC" args "$GN_OUT" --list=target_cpu | python3 "$ROOT/scripts/render_args.py" --parse-gn-value || true)"
fi
if [[ "$GOT_CPU" != "$EXPECT_CPU" ]]; then
  echo "error: gn target_cpu=$GOT_CPU want $EXPECT_CPU for $TRIPLE" >&2
  gn --root="$SRC" args "$GN_OUT" --list=target_cpu || true
  exit 1
fi

if [[ -n "${NINJA_JOBS:-}" ]]; then
  ninja -C "$GN_OUT" -j "$NINJA_JOBS" webrtc api:field_trials
else
  ninja -C "$GN_OUT" webrtc api:field_trials
fi

LIB=""
for cand in obj/libwebrtc.a libwebrtc.a obj/webrtc/libwebrtc.a; do
  if [[ -f "$GN_OUT/$cand" ]]; then
    LIB="$GN_OUT/$cand"
    break
  fi
done
if [[ -z "$LIB" ]]; then
  echo "error: libwebrtc.a not found under $GN_OUT" >&2
  exit 1
fi
FT=""
for cand in obj/api/field_trials.o obj/api/field_trials/field_trials.o obj/api/libfield_trials.a; do
  if [[ -f "$GN_OUT/$cand" ]]; then
    FT="$GN_OUT/$cand"
    break
  fi
done
if [[ -z "$FT" ]]; then
  FT="$(find "$GN_OUT/obj/api" \( -name 'field_trials.o' -o -name 'libfield_trials.a' \) 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$FT" ]]; then
  echo "error: api:field_trials output not found under $GN_OUT" >&2
  exit 1
fi
mkdir -p "$DEST/lib" "$DEST/include"
cp "$LIB" "$DEST/lib/libwebrtc.a"
# Duplicates, counted before and after this script touches the archive. An
# archive with two members of the same name is a mixed archive, and everything
# that extracts by name sees only one of them -- which is how a linux-arm64
# asset shipped with darwin objects in it while two checks reported ELF. If the
# count is already non-zero here, it came out of ninja; if it appears after the
# ar below, it is this line.
dup_count() { ar t "$1" 2>/dev/null | grep -vE '^/' | sort | uniq -d | wc -l | tr -d ' '; }
echo "duplicate members: $LIB -> $(dup_count "$LIB")"
# `webrtc` complete_static_lib does not include embedder-only FieldTrials::Create.
ar r "$DEST/lib/libwebrtc.a" "$FT"
echo "duplicate members: $DEST/lib/libwebrtc.a -> $(dup_count "$DEST/lib/libwebrtc.a") (after ar r)"
# No lipo on Linux: take one member out and ask `file` what it is. A slice built
# for the wrong machine is the failure this catches (an x86_64 archive links
# perfectly well on arm64, it just dies at runtime).
OBJ_PROBE="$(mktemp -d)"
trap 'rm -rf "$OBJ_PROBE"' EXIT
# Every member, not one sampled one. A slice that mixed architectures was
# published once and only failed at a consumer's link, because the single sampled
# member happened to be right -- and on a host whose ar lists GNU long names by
# offset, the sample was not even a real member. One wrong object makes the whole
# slice unlinkable, so the check walks all of them.
bad=0
total=0
while IFS= read -r member; do
  if [[ -z "$member" || "$member" == "/" ]]; then
    continue
  fi
  total=$((total + 1))
  if ! ar p "$DEST/lib/libwebrtc.a" "$member" >"$OBJ_PROBE/probe.o" 2>/dev/null; then
    continue
  fi
  ELF="$(file "$OBJ_PROBE/probe.o")"
  if ! echo "$ELF" | grep -Eq "ELF 64-bit.*$EXPECT_FILE"; then
    echo "error: member $member is not $EXPECT_FILE ($ELF)" >&2
    bad=$((bad + 1))
    [[ $bad -gt 3 ]] && break
  fi
done < <(ar t "$DEST/lib/libwebrtc.a")
if [[ $bad -gt 0 ]]; then
  echo "error: $DEST/lib/libwebrtc.a has members that are not $EXPECT_FILE" >&2
  exit 1
fi
echo "elf ok: all $total members are $EXPECT_FILE"

rsync -a --prune-empty-dirs \
  --exclude='out/' --exclude='.git/' \
  --include='*/' --include='*.h' --include='*.hpp' --include='*.inc' --exclude='*' \
  "$SRC"/ "$DEST/include/"

if command -v nm >/dev/null; then
  if nm "$DEST/lib/libwebrtc.a" 2>/dev/null | grep -Eiq 'avcodec_|av_codec'; then
    echo "error: libwebrtc.a exports avcodec_*; rtc_use_h264 must stay false" >&2
    exit 1
  fi
  if ! (nm -C "$DEST/lib/libwebrtc.a" 2>/dev/null || true) | grep -q 'FieldTrials::Create'; then
    echo "error: libwebrtc.a missing webrtc::FieldTrials::Create; ninja api:field_trials" >&2
    exit 1
  fi
fi

echo "ok $TRIPLE"
echo "  LIBWEBRTC_INCLUDE_PATH=$DEST/include"
echo "  LIBWEBRTC_BINARY_PATH=$DEST/lib"
