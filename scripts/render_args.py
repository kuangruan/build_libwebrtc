#!/usr/bin/env python3
"""Write args.gn + BUILD_INFO.json for one first-wave triple."""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIPLES_PATH = ROOT / "config" / "triples.txt"
FLAGS_PATH = ROOT / "config" / "gn-flags.txt"
MILESTONE_PATH = ROOT / "config" / "milestone.env"
FORBIDDEN = ("rtc_use_h264=true", "proprietary_codecs=true")


def load_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def load_triples() -> dict[str, dict[str, str]]:
    triples: dict[str, dict[str, str]] = {}
    for raw in TRIPLES_PATH.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        name, host_os, gn_os, gn_cpu, lib_name = line.split()
        triples[name] = {
            "name": name,
            "host_os": host_os,
            "gn_os": gn_os,
            "gn_cpu": gn_cpu,
            "lib_name": lib_name,
        }
    return triples


def load_flags() -> list[str]:
    flags: list[str] = []
    for raw in FLAGS_PATH.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            flags.append(line)
    return flags


def assignments(text: str) -> list[str]:
    out: list[str] = []
    for raw in text.splitlines():
        compact = "".join(raw.split("#", 1)[0].split())
        if compact:
            out.append(compact)
    return out


def assert_args_ok(text: str) -> None:
    got = assignments(text)
    for bad in FORBIDDEN:
        if "".join(bad.split()) in got:
            raise SystemExit(f"args.gn must not contain {bad}")
    for flag in load_flags():
        if "".join(flag.split()) not in got:
            raise SystemExit(f"args.gn missing {flag}")


def parse_gn_listed_value(text: str) -> str:
    """Extract the quoted value from `gn args --list=NAME [--short]`.

    `--short` prints `target_cpu = "arm64"`. Stripping spaces/quotes from that
    line yields `target_cpu=arm64`, which is not the cpu name.
    The long listing has `Current value = "arm64"`.
    """
    for raw in text.splitlines():
        line = raw.strip()
        if '"' not in line:
            continue
        if "=" not in line and "Current value" not in line:
            continue
        start = line.find('"')
        end = line.find('"', start + 1)
        if start >= 0 and end > start:
            return line[start + 1 : end]
    return ""


def flatten_gn_args(text: str) -> str:
    """Strip comments so `gn --args=` does not treat the rest of the file as a comment."""
    parts: list[str] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            parts.append(line)
    return " ".join(parts)


def render_args_gn(triple: dict[str, str]) -> str:
    lines = [
        "# Frozen GN. Do not enable webrtc H.264 / Chromium FFmpeg.",
        *load_flags(),
        f'target_os="{triple["gn_os"]}"',
        f'target_cpu="{triple["gn_cpu"]}"',
        "",
    ]
    text = "\n".join(lines)
    assert_args_ok(text)
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description="Render frozen args.gn")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--triple")
    parser.add_argument("--dest")
    parser.add_argument("--script", choices=("sh", "ps1"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--commit", default="")
    parser.add_argument("--include-path", default="")
    parser.add_argument(
        "--flatten",
        metavar="ARGS_GN",
        help="print comment-stripped GN args from an args.gn file",
    )
    parser.add_argument(
        "--parse-gn-value",
        action="store_true",
        help="read gn --list output on stdin and print the quoted value",
    )
    args = parser.parse_args()

    if args.flatten:
        print(flatten_gn_args(Path(args.flatten).read_text()))
        return 0
    if args.parse_gn_value:
        value = parse_gn_listed_value(sys.stdin.read())
        if not value:
            print("error: no quoted gn value on stdin", file=sys.stderr)
            return 1
        print(value)
        return 0

    triples = load_triples()
    if args.list:
        for name in triples:
            print(name)
        return 0

    if not args.triple or not args.dest:
        print("error: --triple and --dest are required", file=sys.stderr)
        return 1
    if args.triple not in triples:
        names = ", ".join(triples)
        print(f"error: unknown triple {args.triple!r}; want one of {names}", file=sys.stderr)
        return 1

    triple = triples[args.triple]
    if args.script == "sh" and triple["host_os"] != "darwin":
        print(f"error: {args.triple} must be built with scripts/build-windows.ps1", file=sys.stderr)
        return 1
    if args.script == "ps1" and triple["host_os"] != "windows":
        print(f"error: {args.triple} must be built with scripts/build-darwin.sh", file=sys.stderr)
        return 1

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "lib").mkdir(exist_ok=True)
    gn = render_args_gn(triple)
    (dest / "args.gn").write_text(gn)
    meta = load_env(MILESTONE_PATH)
    info = {
        "triple": triple["name"],
        "branch": meta["WEBRTC_BRANCH"],
        "milestone": meta["WEBRTC_MILESTONE"],
        "artifact_tree": meta["ARTIFACT_TREE"],
        "commit": args.commit or ("dry-run" if args.dry_run else "unknown"),
        "gn_args": gn,
        "generated_at_unix": int(time.time()),
        "dry_run": bool(args.dry_run),
        "lib_name": triple["lib_name"],
        "include_path": args.include_path,
        "binary_path": str(dest / "lib"),
    }
    (dest / "BUILD_INFO.json").write_text(json.dumps(info, indent=2) + "\n")
    inc = args.include_path or "<set-after-checkout>/src"
    (dest / "env.sh").write_text(
        f"export LIBWEBRTC_INCLUDE_PATH={inc!r}\n"
        f"export LIBWEBRTC_BINARY_PATH={str(dest / 'lib')!r}\n"
    )
    (dest / "env.ps1").write_text(
        f"$env:LIBWEBRTC_INCLUDE_PATH = {inc!r}\n"
        f"$env:LIBWEBRTC_BINARY_PATH = {str(dest / 'lib')!r}\n"
    )
    print(dest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
