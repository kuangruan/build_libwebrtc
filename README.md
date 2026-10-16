# build_libwebrtc

Standalone **Google libwebrtc M140** (`branch-heads/7339`) packager.

This repo is only build scripts + GitHub Actions. It does **not** contain
application source. Artifacts (headers + static lib) go to GitHub Releases /
Actions artifacts, never into git.

| triple | runner | output |
|--------|--------|--------|
| `darwin-arm64` | macOS | `libwebrtc.a` |
| `darwin-x86_64` | macOS | `libwebrtc.a` |
| `linux-arm64` | Linux arm64 | `libwebrtc.a` |
| `windows-x86_64` | Windows | `webrtc.lib` |
| `windows-x86` | Windows | `webrtc.lib` |

Frozen GN includes `rtc_use_h264=false` and `proprietary_codecs=false`.
`linux-arm64` is built natively on the arm64 runner; `scripts/build-linux.sh
--cross` also builds it from an x86_64 Linux host by adding `use_sysroot=true`
(that appends to the generated args, it is not part of the frozen set).

## Local

```bash
# macOS
./scripts/build-darwin.sh --dry-run --triple darwin-arm64
./scripts/build-darwin.sh --triple darwin-arm64

# Linux (arm64 natively, or any host with --cross)
./scripts/build-linux.sh --dry-run --triple linux-arm64
./scripts/build-linux.sh --triple linux-arm64

# Windows (Developer PowerShell)
.\scripts\build-windows.ps1 -DryRun -Triple windows-x86_64
.\scripts\build-windows.ps1 -Triple windows-x86_64
```

## CI

- `test.yml` — dry-run / contract checks on every push
- `build.yml` — full ninja build (`workflow_dispatch`, one or all triples)

After a slice builds, set:

- `LIBWEBRTC_INCLUDE_PATH` → unpacked `include/`
- `LIBWEBRTC_BINARY_PATH` → unpacked `lib/`
