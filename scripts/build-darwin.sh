#!/usr/bin/env bash
# Standalone M140 libwebrtc packager for darwin-arm64 / darwin-x86_64.
# Windows slices: scripts/build-windows.ps1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/milestone.env"

TRIPLE=""
DEST=""
CHECKOUT="${WEBRTC_CHECKOUT:-}"
DRY_RUN=0
SKIP_FETCH=0

usage() {
  cat <<'EOF'
Usage: build-darwin.sh [--triple darwin-arm64|darwin-x86_64] [--dest DIR]
                       [--checkout DIR] [--dry-run] [--skip-fetch] [--help]

Default triple is this Mac. Does not build Windows.
Does not download third-party prebuilt webrtc tarballs.
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
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) TRIPLE=darwin-arm64 ;;
    Darwin-x86_64) TRIPLE=darwin-x86_64 ;;
    *)
      echo "error: pass --triple darwin-arm64 or darwin-x86_64" >&2
      exit 1
      ;;
  esac
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: build-darwin.sh only runs on macOS" >&2
  exit 1
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
  if [[ ! -d "$SRC/.git" ]]; then
    echo "fetch webrtc (no-history) into $CHECKOUT"
    rm -rf "$SRC"
    retry bash -c 'cd "$1" && fetch --nohooks --no-history webrtc' _ "$CHECKOUT"
  fi
  retry bash -c '
    set -euo pipefail
    cd "$1"
    git -c http.version=HTTP/1.1 -c credential.helper= fetch --depth=1 origin "+'"$WEBRTC_REF"':refs/remotes/'"$WEBRTC_BRANCH"'"
    git checkout -B m140-7339 '"$WEBRTC_BRANCH"'
    gclient sync -D --no-history
  ' _ "$SRC"
fi

if [[ ! -d "$SRC" ]]; then
  echo "error: missing $SRC" >&2
  exit 1
fi

COMMIT="$(git -C "$SRC" rev-parse HEAD)"
DEST="$(plan "$DEST" --commit "$COMMIT" --include-path "$SRC")"

# depot_tools' gn is a wrapper; gn.py requires a second real `gn` on PATH
# (CIPD binary under src/buildtools/mac).
ensure_gn() {
  local bin="" cand
  for cand in \
    "$SRC/buildtools/mac/gn" \
    "$SRC/third_party/gn/gn" \
    "$SRC/buildtools/mac/clang_x64/gn"; do
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
    ls -la "$SRC/buildtools/mac" 2>/dev/null || true
    return 1
  fi
  export PATH="$(dirname "$bin"):$DEPOT:$PATH"
  hash -r || true
  echo "using gn $bin"
  gn --version
}

ensure_gn

GN_OUT="$SRC/out/$TRIPLE"
mkdir -p "$GN_OUT"
cp "$DEST/args.gn" "$GN_OUT/args.gn"
if [[ ! -f "$SRC/.gn" ]]; then
  echo "error: missing $SRC/.gn (gclient sync incomplete)" >&2
  exit 1
fi
# Real gn walks cwd for .gn. Actions cwd is this repo, not the WebRTC tree.
gn --root="$SRC" gen "$GN_OUT" --args="$(tr '\n' ' ' < "$DEST/args.gn")"

if [[ -n "${NINJA_JOBS:-}" ]]; then
  ninja -C "$GN_OUT" -j "$NINJA_JOBS" webrtc
else
  ninja -C "$GN_OUT" webrtc
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
mkdir -p "$DEST/lib" "$DEST/include"
cp "$LIB" "$DEST/lib/libwebrtc.a"
rsync -a --prune-empty-dirs \
  --exclude='out/' --exclude='.git/' \
  --include='*/' --include='*.h' --include='*.hpp' --include='*.inc' --exclude='*' \
  "$SRC"/ "$DEST/include/"

if command -v nm >/dev/null; then
  if nm "$DEST/lib/libwebrtc.a" 2>/dev/null | grep -Eiq 'avcodec_|av_codec'; then
    echo "error: libwebrtc.a exports avcodec_*; rtc_use_h264 must stay false" >&2
    exit 1
  fi
fi

echo "ok $TRIPLE"
echo "  LIBWEBRTC_INCLUDE_PATH=$DEST/include"
echo "  LIBWEBRTC_BINARY_PATH=$DEST/lib"
