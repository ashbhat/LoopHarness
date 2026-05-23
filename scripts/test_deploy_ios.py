#!/usr/bin/env python3
"""
Diagnostic helper for deploy_ios.py.

It runs the same Xcode commands (optionally with a timeout) so you can
quickly see which step is hanging on your machine.
"""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Probe xcodebuild commands used by deploy_ios.py.")
    parser.add_argument("--scheme", default="intel_ios", help="Xcode scheme to target.")
    parser.add_argument("--configuration", default="Release", help="Build configuration.")
    parser.add_argument(
        "--project",
        default="intel.xcodeproj",
        help=".xcodeproj to use (ignored when --workspace is supplied).",
    )
    parser.add_argument("--workspace", help="Optional .xcworkspace to use instead of the project.")
    parser.add_argument(
        "--derived-data",
        default="build/ios-diagnostics",
        help="Derived data output for the build probe.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=45,
        help="Seconds to wait before timing out a subprocess (default: %(default)s).",
    )
    parser.add_argument(
        "--skip-build-settings",
        action="store_true",
        help="Do not run xcodebuild -showBuildSettings.",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Do not run the clean+build portion.",
    )
    return parser.parse_args()


def run_with_timeout(cmd: list[str], timeout: int) -> subprocess.CompletedProcess:
    pretty_cmd = " ".join(shlex.quote(part) for part in cmd)
    print(f"\n$ {pretty_cmd}", flush=True)
    start = time.monotonic()
    try:
        result = subprocess.run(cmd, check=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        duration = time.monotonic() - start
        sys.exit(
            f"Command timed out after {duration:.1f}s (limit {timeout}s).\n"
            "This is the step that is hanging."
        )
    duration = time.monotonic() - start
    print(f"(finished in {duration:.1f}s)")
    return result


def ensure_path(path: str | None, label: str) -> None:
    if not path:
        return
    resolved = Path(path).expanduser()
    if not resolved.exists():
        sys.exit(f"{label} not found at {resolved}")


def main() -> None:
    args = parse_args()
    ensure_path(args.workspace, "Workspace")
    ensure_path(args.project, "Project")

    base = ["xcodebuild"]
    if args.workspace:
        base += ["-workspace", args.workspace]
    else:
        base += ["-project", args.project]
    base += ["-scheme", args.scheme, "-configuration", args.configuration]

    if not args.skip_build_settings:
        run_with_timeout(base + ["-showBuildSettings"], args.timeout)

    if not args.skip_build:
        build_cmd = base + [
            "-sdk",
            "iphoneos",
            "-derivedDataPath",
            str(Path(args.derived_data).expanduser()),
            "clean",
            "build",
        ]
        run_with_timeout(build_cmd, args.timeout)

    print("\nDiagnostics completed without a hang.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("Aborted by user.")
