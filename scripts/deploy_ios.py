#!/usr/bin/env python3
"""
Build the Loop iOS target and deploy it to a tethered device via ios-deploy.

Example:
    python scripts/deploy_ios.py --device-id <YOUR_DEVICE_UDID>
"""

from __future__ import annotations

import argparse
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable, Optional, Tuple


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compile the Loop iOS app and push it to a connected iPhone."
    )
    parser.add_argument(
        "--scheme",
        default="Loop",
        help="Xcode scheme to build (default: %(default)s).",
    )
    parser.add_argument(
        "--configuration",
        default="Release",
        help="Build configuration (default: %(default)s).",
    )
    parser.add_argument(
        "--destination",
        action="append",
        help=(
            "Destination specifier passed to xcodebuild -destination. "
            "Repeat to provide multiple destinations. "
            "Defaults to 'generic/platform=iOS'."
        ),
    )
    parser.add_argument(
        "--project",
        default="Loop.xcodeproj",
        help="Path to the .xcodeproj to build (ignored when --workspace is supplied).",
    )
    parser.add_argument(
        "--workspace",
        help="Optional .xcworkspace to build instead of the project.",
    )
    parser.add_argument(
        "--derived-data",
        default="build/ios",
        help="Derived data output directory (default: %(default)s).",
    )
    parser.add_argument(
        "--clean-build",
        action="store_true",
        help="Force xcodebuild clean before building (slower, but ensures a pristine build).",
    )
    parser.add_argument(
        "--reuse-build",
        action="store_true",
        help="Skip the build step when an existing .app bundle is already present in derived data.",
    )
    parser.add_argument(
        "--device-id",
        help="UDID of the target device (passed to ios-deploy --id). Defaults to the first tethered device discovered by xcrun xctrace.",
    )
    parser.add_argument(
        "--product-name",
        help="Override the expected FULL_PRODUCT_NAME (e.g. Loop.app).",
    )
    parser.add_argument(
        "--build-only",
        action="store_true",
        help="Only build the app; skip ios-deploy.",
    )
    parser.add_argument(
        "--skip-launch",
        action="store_true",
        help="Install without launching (omit ios-deploy --justlaunch).",
    )
    parser.add_argument(
        "--no-provisioning-updates",
        action="store_true",
        help="Do not pass -allowProvisioningUpdates to xcodebuild.",
    )
    parser.add_argument(
        "--ios-deploy-binary",
        default="ios-deploy",
        help="Path to the ios-deploy executable (default: %(default)s).",
    )
    parser.add_argument(
        "--ios-deploy-arg",
        action="append",
        default=[],
        help="Extra flag forwarded to ios-deploy (repeatable).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print full command output and skip xcodebuild -quiet.",
    )
    return parser.parse_args()


def ensure_tool_exists(binary: str, friendly_name: Optional[str] = None) -> None:
    if shutil.which(binary):
        return
    label = friendly_name or binary
    sys.exit(f"Missing required tool '{label}'. Install it and retry.")


def shlex_join(parts: Iterable[object]) -> str:
    return " ".join(shlex.quote(str(part)) for part in parts)


def run_command(cmd: Iterable[object], label: Optional[str] = None, verbose: bool = False) -> None:
    if label:
        print(label, flush=True)
    if verbose:
        print(f"\n$ {shlex_join(cmd)}\n", flush=True)
    subprocess.run(cmd, check=True)


DEVICE_LINE_RE = re.compile(
    r"^(?P<label>.+?) \((?P<version>.+?)\) \((?P<udid>[0-9A-Fa-f-]+)\)(?: \((?P<status>.+?)\))?$"
)


def autodetect_device_id() -> Optional[str]:
    """Return the first tethered physical device reported by xctrace."""
    try:
        result = subprocess.run(
            ["xcrun", "xctrace", "list", "devices"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        print("xcrun not found; cannot auto-detect device.", file=sys.stderr)
        return None
    except subprocess.CalledProcessError as exc:
        print(
            "xcrun xctrace failed; cannot auto-detect device.\n"
            f"stdout:\n{exc.stdout}\n\nstderr:\n{exc.stderr}",
            file=sys.stderr,
        )
        return None

    devices: list[Tuple[str, str]] = []
    section = None
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("=="):
            section = line
            continue
        if section and "Simulated" in section:
            continue
        match = DEVICE_LINE_RE.match(line)
        if not match:
            continue
        label = match.group("label")
        udid = match.group("udid")
        status = (match.group("status") or "").lower()
        # Filter out Macs and other non-iOS targets.
        if "mac" in label.lower():
            continue
        if status and "unavailable" in status:
            continue
        devices.append((label, udid))

    if not devices:
        return None

    label, udid = devices[0]
    print(f"Auto-selecting device '{label}' ({udid}).", flush=True)
    return udid


def fetch_full_product_name(args: argparse.Namespace) -> Optional[str]:
    print("Resolving FULL_PRODUCT_NAME via xcodebuild -showBuildSettings...", flush=True)
    base_cmd = ["xcodebuild"]
    if args.workspace:
        base_cmd += ["-workspace", args.workspace]
    else:
        base_cmd += ["-project", args.project]
    base_cmd += [
        "-scheme",
        args.scheme,
        "-configuration",
        args.configuration,
        "-showBuildSettings",
    ]
    try:
        result = subprocess.run(
            base_cmd,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as exc:
        print(
            "Failed to read build settings; falling back to filesystem search.\n"
            f"Command output:\n{exc.stdout}",
            file=sys.stderr,
        )
        return None
    except KeyboardInterrupt:
        raise
    except Exception as exc:  # pragma: no cover - defensive guardrail
        print(
            f"Unable to resolve build settings: {exc}. Falling back to filesystem search.",
            file=sys.stderr,
        )
        return None

    for line in result.stdout.splitlines():
        if "FULL_PRODUCT_NAME" in line:
            _, value = line.split("=", 1)
            sanitized = value.strip()
            if sanitized:
                return sanitized
    return None


def build_app(args: argparse.Namespace) -> None:
    cmd = ["xcodebuild"]
    if args.workspace:
        cmd += ["-workspace", args.workspace]
    else:
        cmd += ["-project", args.project]
    cmd += [
        "-scheme",
        args.scheme,
        "-configuration",
        args.configuration,
        "-sdk",
        "iphoneos",
        "-derivedDataPath",
        args.derived_data,
    ]
    destinations = args.destination or ["generic/platform=iOS"]
    for dest in destinations:
        cmd += ["-destination", dest]
    if not args.no_provisioning_updates:
        cmd.append("-allowProvisioningUpdates")
    if not args.verbose:
        cmd.append("-quiet")
    phases: list[str] = []
    if args.clean_build:
        phases.append("clean")
    phases.append("build")
    cmd += phases
    run_command(
        cmd,
        label=f"Building scheme {args.scheme} ({args.configuration})...",
        verbose=args.verbose,
    )


def locate_existing_app_bundle(args: argparse.Namespace, product_hint: Optional[str]) -> Optional[Path]:
    products_dir = Path(args.derived_data) / "Build" / "Products"
    sdk_dir = products_dir / f"{args.configuration}-iphoneos"
    if not sdk_dir.exists():
        return None

    if product_hint:
        hinted = sdk_dir / product_hint
        if hinted.exists():
            return hinted

    apps = sorted(
        sdk_dir.glob("*.app"),
        key=lambda candidate: candidate.stat().st_mtime,
        reverse=True,
    )
    if not apps:
        return None
    return apps[0]


def find_app_bundle(args: argparse.Namespace, product_hint: Optional[str]) -> Path:
    sdk_dir = Path(args.derived_data) / "Build" / "Products" / f"{args.configuration}-iphoneos"
    app = locate_existing_app_bundle(args, product_hint)
    if app:
        if product_hint and app.name != product_hint:
            print(
                f"Unable to locate {product_hint}; using most recent build: {app.name}"
            )
        return app

    if not sdk_dir.exists():
        sys.exit(f"Build output folder {sdk_dir} not found.")
    sys.exit(f"No .app bundle found under {sdk_dir}.")


def deploy_to_device(app_path: Path, args: argparse.Namespace, device_id: str) -> None:
    cmd: list[object] = [args.ios_deploy_binary, "--bundle", str(app_path)]
    cmd += ["--id", device_id]
    if not args.skip_launch:
        cmd.append("--justlaunch")
    if args.ios_deploy_arg:
        cmd += args.ios_deploy_arg
    run_command(
        cmd,
        label=f"Installing on device {device_id}...",
        verbose=args.verbose,
    )


def normalize_paths(args: argparse.Namespace) -> None:
    derived = Path(args.derived_data).expanduser()
    if not derived.is_absolute():
        derived = (Path.cwd() / derived).resolve()
    args.derived_data = str(derived)

    if args.workspace:
        workspace = Path(args.workspace).expanduser()
        if not workspace.exists():
            sys.exit(f"Workspace {workspace} not found.")
        args.workspace = str(workspace.resolve())
    else:
        project = Path(args.project).expanduser()
        if not project.exists():
            sys.exit(f"Project {project} not found.")
        args.project = str(project.resolve())


def resolve_device_id(args: argparse.Namespace) -> str:
    if args.device_id:
        device_id = args.device_id.strip()
        if device_id:
            return device_id
    detected = autodetect_device_id()
    if detected:
        return detected
    sys.exit(
        "No device ID provided and auto-detection failed. "
        "Connect an iOS device or pass --device-id explicitly."
    )


def main() -> None:
    args = parse_args()
    normalize_paths(args)

    ensure_tool_exists("xcodebuild", "xcodebuild (Xcode command-line tools)")
    if not args.build_only:
        ensure_tool_exists(args.ios_deploy_binary, "ios-deploy")

    product_hint = args.product_name
    app_path: Optional[Path] = None

    if args.reuse_build:
        cached_app = locate_existing_app_bundle(args, product_hint)
        if cached_app:
            if product_hint and cached_app.name != product_hint:
                print(
                    f"Unable to locate {product_hint}; using most recent build: {cached_app.name}"
                )
            print(f"Reusing cached build at {cached_app}. Skipping xcodebuild.")
            app_path = cached_app
        else:
            print(
                "No cached build artifacts match the current configuration. Triggering a fresh build."
            )

    if app_path is None:
        if not product_hint:
            product_hint = fetch_full_product_name(args)
        try:
            build_app(args)
        except subprocess.CalledProcessError as exc:
            sys.exit(exc.returncode)
        app_path = find_app_bundle(args, product_hint)

    print(f"App bundle: {app_path}")

    if args.build_only:
        print("Build completed. Skipping deployment as requested.")
        return

    device_id = resolve_device_id(args)

    try:
        deploy_to_device(app_path, args, device_id)
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.returncode)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("Aborted by user.")
