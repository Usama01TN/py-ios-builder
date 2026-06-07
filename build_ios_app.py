#!/usr/bin/env python3
"""
build_ios_app.py — one-shot orchestrator for building YOUR PySide6 app on iOS
using the pyside6-ios toolkit.

What this does, in order:
  1. Reads your pyside6-ios.toml and resolves the toolkit + Qt SDK paths.
  2. Verifies (and optionally builds) the prerequisites the toolkit assumes
     already exist:
        - build/python/Python.xcframework  (BeeWare CPython for iOS)
        - QtRuntime.framework               (scripts/build_qtruntime.sh)
        - libshiboken6/libpyside6/...       (scripts/build_support_libs.sh)
        - libPySide6_<Module>.a for every [pyside6].modules entry
                                            (scripts/build_pyside6_module.sh)
  3. Sanity-checks your vendored Python deps for iOS-incompatible C extensions.
  4. Runs `pyside6-ios -c <toml> generate|build [--install]`.

This must run on macOS (Apple Silicon) with Xcode + the `pyside6-ios` package
installed (`uv pip install -e .` from the toolkit root). It is a thin, safe
wrapper around the toolkit's own scripts and CLI — it does not reimplement them.

Usage:
    python build_ios_app.py --config path/to/pyside6-ios.toml \
        --configuration Debug \
        --destination 'id=XCODE_UDID' \
        --install \
        --build-prereqs            # build missing QtRuntime/support/modules

    # Just check that everything is in place, build nothing:
    python build_ios_app.py --config path/to/pyside6-ios.toml --check-only

    # Launch + stream console after install (needs CoreDevice UUID):
    python build_ios_app.py --config ... --install \
        --destination 'id=XCODE_UDID' \
        --launch-device COREDEVICE_UUID
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import tomllib  # py3.11+
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #
class BuildError(RuntimeError):
    pass


def info(msg: str) -> None:
    print(f"\033[1;34m==>\033[0m {msg}")


def ok(msg: str) -> None:
    print(f"  \033[1;32m✓\033[0m {msg}")


def warn(msg: str) -> None:
    print(f"  \033[1;33m!\033[0m {msg}")


def run(cmd, cwd=None, env=None) -> None:
    printable = cmd if isinstance(cmd, str) else " ".join(map(str, cmd))
    info(f"run: {printable}")
    subprocess.run(cmd, cwd=cwd, env=env, shell=isinstance(cmd, str), check=True)


def expand(base: Path, p: str) -> Path:
    e = Path(os.path.expanduser(p))
    return e if e.is_absolute() else (base / e).resolve()


# --------------------------------------------------------------------------- #
# config loading (mirrors the subset of pyside6_ios.config we need, so the
# script can run without importing the package and give friendlier errors)
# --------------------------------------------------------------------------- #
class Cfg:
    def __init__(self, toml_path: Path):
        self.toml_path = toml_path.resolve()
        self.project_root = self.toml_path.parent
        with open(self.toml_path, "rb") as fh:
            raw = tomllib.load(fh)

        app = raw.get("app", {})
        paths = raw.get("paths", {})
        pyside6 = raw.get("pyside6", {})
        python = raw.get("python", {})

        if "name" not in app:
            raise BuildError("[app].name is required in the TOML")

        self.name: str = app["name"]
        self.product_name = self.name.replace(" ", "")
        self.modules: list[str] = pyside6.get("modules", [])

        self.pyside6_ios = expand(self.project_root, paths.get("pyside6-ios", ""))
        # QT_IOS env overrides the toml, same as the toolkit does.
        self.qt_ios = expand(
            self.project_root,
            os.environ.get("QT_IOS", paths.get("qt-ios", "")),
        )
        self.output_dir = expand(self.project_root, paths.get("output-dir", "build/ios"))
        self.vendor_dir = python.get("vendor-dir", "")


# --------------------------------------------------------------------------- #
# prerequisite checks
# --------------------------------------------------------------------------- #
def check_host() -> None:
    info("Checking host environment")
    if sys.platform != "darwin":
        raise BuildError(
            "iOS builds require macOS. This script must run on a Mac with Xcode."
        )
    if platform.machine() not in ("arm64", "aarch64"):
        warn(f"host arch is {platform.machine()}; toolkit is tested on Apple Silicon")
    if shutil.which("xcrun") is None:
        raise BuildError("xcrun not found — install Xcode and command line tools.")
    # Make sure xcode-select points at a full Xcode, not bare CLT.
    try:
        dev = subprocess.run(
            ["xcode-select", "-p"], capture_output=True, text=True, check=True
        ).stdout.strip()
        ok(f"xcode-select -> {dev}")
        if dev.endswith("CommandLineTools"):
            warn(
                "xcode-select points at CommandLineTools. Run:\n"
                "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
            )
    except subprocess.CalledProcessError:
        warn("could not query xcode-select")
    if shutil.which("pyside6-ios") is None:
        warn(
            "pyside6-ios CLI not on PATH. From the toolkit root run:\n"
            "      uv pip install -e ."
        )


def check_paths(cfg: Cfg) -> None:
    info("Checking toolkit + Qt SDK paths")
    if not cfg.pyside6_ios.exists():
        raise BuildError(f"[paths].pyside6-ios not found: {cfg.pyside6_ios}")
    ok(f"pyside6-ios toolkit: {cfg.pyside6_ios}")
    if not cfg.qt_ios.exists():
        raise BuildError(
            f"Qt iOS SDK not found: {cfg.qt_ios}\n"
            "    Set it via QT_IOS env var or [paths].qt-ios in the TOML."
        )
    if not (cfg.qt_ios / "lib" / "QtCore.framework").exists():
        raise BuildError(
            f"Qt iOS SDK at {cfg.qt_ios} has no lib/QtCore.framework — "
            "is this the 'ios' SDK directory?"
        )
    ok(f"Qt iOS SDK: {cfg.qt_ios}")


def check_python_xcframework(cfg: Cfg, fix: bool) -> None:
    info("Checking CPython iOS framework")
    fw = (
        cfg.pyside6_ios
        / "build/python/Python.xcframework/ios-arm64/Python.framework"
    )
    patchlevel = fw / "Headers/patchlevel.h"
    if patchlevel.exists():
        ver = "?"
        m = re.search(r'#define\s+PY_VERSION\s+"(\d+\.\d+)', patchlevel.read_text())
        if m:
            ver = m.group(1)
        ok(f"Python.xcframework present (Python {ver})")
        return
    msg = (
        "Python.xcframework missing. Download BeeWare's CPython iOS support, e.g.:\n"
        "      mkdir -p build/python && curl -L "
        "https://github.com/beeware/Python-Apple-support/releases/download/"
        "3.13-b13/Python-3.13-iOS-support.b13.tar.gz | tar -xz -C build/python/"
    )
    if not fix:
        raise BuildError(msg)
    warn("Python.xcframework missing and cannot be auto-downloaded safely here.")
    raise BuildError(msg)


def _script(cfg: Cfg, name: str) -> Path:
    return cfg.pyside6_ios / "scripts" / name


def check_qtruntime(cfg: Cfg, fix: bool) -> None:
    info("Checking QtRuntime.framework")
    candidates = list(
        (cfg.pyside6_ios / "build").rglob("QtRuntime.framework")
    )
    if candidates:
        ok(f"QtRuntime.framework present: {candidates[0]}")
        return
    if not fix:
        raise BuildError(
            "QtRuntime.framework missing. Build it with:\n"
            f"      {_script(cfg, 'build_qtruntime.sh')}\n"
            "    (or re-run this script with --build-prereqs)"
        )
    run([str(_script(cfg, "build_qtruntime.sh"))], cwd=cfg.pyside6_ios)


def check_support_libs(cfg: Cfg, fix: bool) -> None:
    info("Checking support libraries (libshiboken6 / libpyside6 / libpysideqml)")
    static_dir = cfg.pyside6_ios / "build/pyside6-ios-static"
    needed = ["libshiboken6.a", "libpyside6.a"]
    missing = [n for n in needed if not (static_dir / n).exists()]
    if not missing:
        ok("support libraries present")
        return
    if not fix:
        raise BuildError(
            f"Support libraries missing ({', '.join(missing)}). Build with:\n"
            f"      {_script(cfg, 'build_support_libs.sh')}\n"
            "    (or re-run with --build-prereqs)"
        )
    run([str(_script(cfg, "build_support_libs.sh"))], cwd=cfg.pyside6_ios)


def check_modules(cfg: Cfg, fix: bool) -> None:
    info("Checking cross-compiled PySide6 modules")
    if not cfg.modules:
        warn("no [pyside6].modules listed in TOML — nothing to check")
        return
    static_dir = cfg.pyside6_ios / "build/pyside6-ios-static"
    build_mod = _script(cfg, "build_pyside6_module.sh")
    for mod in cfg.modules:
        lib = static_dir / f"libPySide6_{mod}.a"
        if lib.exists():
            ok(f"{mod}: {lib.name}")
            continue
        if not fix:
            raise BuildError(
                f"PySide6 module {mod} not cross-compiled ({lib} missing).\n"
                f"    Build it with: {build_mod} {mod}\n"
                "    (or re-run with --build-prereqs)"
            )
        run([str(build_mod), mod], cwd=cfg.pyside6_ios)


def check_vendor(cfg: Cfg) -> None:
    if not cfg.vendor_dir:
        return
    info("Checking vendored Python deps for iOS-incompatible C extensions")
    vdir = cfg.project_root / cfg.vendor_dir
    if not vdir.exists():
        warn(f"vendor dir does not exist yet: {vdir}")
        return
    bad = list(vdir.rglob("*.so")) + list(vdir.rglob("*.pyd"))
    if bad:
        warn(
            "Found compiled extensions in vendor/ — these won't load on iOS arm64 "
            "unless cross-compiled separately:"
        )
        for b in bad[:20]:
            print(f"        {b.relative_to(vdir)}")
        if len(bad) > 20:
            print(f"        ... and {len(bad) - 20} more")
    else:
        ok("vendored deps are pure-Python")


# --------------------------------------------------------------------------- #
# driving the CLI
# --------------------------------------------------------------------------- #
def cli_cmd(cfg: Cfg, *args: str) -> list[str]:
    """Prefer the installed console script; fall back to module form."""
    if shutil.which("pyside6-ios"):
        return ["pyside6-ios", "-c", str(cfg.toml_path), *args]
    return [sys.executable, "-m", "pyside6_ios.cli", "-c", str(cfg.toml_path), *args]


def do_generate(cfg: Cfg) -> None:
    info("Generating Xcode project")
    run(cli_cmd(cfg, "generate"), cwd=cfg.project_root)


def do_build(cfg: Cfg, configuration: str, destination: str, install: bool) -> None:
    info(f"Building ({configuration})")
    args = ["build", "--configuration", configuration]
    if destination:
        args += ["--destination", destination]
    if install:
        if not destination:
            raise BuildError("--install requires --destination 'id=XCODE_UDID'")
        args.append("--install")
    run(cli_cmd(cfg, *args), cwd=cfg.project_root)


def do_launch(cfg: Cfg, launch_device: str) -> None:
    info("Launching app on device with console output")
    run(
        [
            "xcrun", "devicectl", "device", "process", "launch",
            "--device", launch_device, "--console",
            _bundle_id(cfg),
        ]
    )


def _bundle_id(cfg: Cfg) -> str:
    with open(cfg.toml_path, "rb") as fh:
        raw = tomllib.load(fh)
    bid = raw.get("app", {}).get("bundle-id")
    if not bid:
        raise BuildError("[app].bundle-id missing; cannot launch.")
    return bid


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="Verify prerequisites and build a PySide6 app for iOS "
        "via the pyside6-ios toolkit.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("-c", "--config", default="pyside6-ios.toml",
                   help="path to your pyside6-ios.toml (default: ./pyside6-ios.toml)")
    p.add_argument("--configuration", default="Debug", choices=["Debug", "Release"])
    p.add_argument("--destination", default="",
                   help="xcodebuild destination, e.g. \"id=XCODE_UDID\" "
                        "(from `xcrun xctrace list devices`)")
    p.add_argument("--install", action="store_true",
                   help="install on device after build (needs --destination)")
    p.add_argument("--launch-device", default="",
                   help="CoreDevice UUID (from `xcrun devicectl list devices`) "
                        "to launch + stream console after install")
    p.add_argument("--build-prereqs", action="store_true",
                   help="build any missing QtRuntime/support-libs/modules")
    p.add_argument("--check-only", action="store_true",
                   help="only verify prerequisites; do not generate or build")
    p.add_argument("--generate-only", action="store_true",
                   help="stop after generating the .xcodeproj")
    p.add_argument("--skip-checks", action="store_true",
                   help="skip prerequisite verification (assume environment is ready)")
    args = p.parse_args(argv)

    toml_path = Path(args.config)
    if not toml_path.exists():
        print(f"ERROR: config not found: {toml_path}", file=sys.stderr)
        return 2

    try:
        cfg = Cfg(toml_path)
        info(f"App: {cfg.name}  (modules: {', '.join(cfg.modules) or 'none'})")
        info(f"Project root: {cfg.project_root}")
        info(f"Output dir:   {cfg.output_dir}")

        if not args.skip_checks:
            check_host()
            check_paths(cfg)
            fix = args.build_prereqs
            check_python_xcframework(cfg, fix)
            check_qtruntime(cfg, fix)
            check_support_libs(cfg, fix)
            check_modules(cfg, fix)
            check_vendor(cfg)
            info("All prerequisites satisfied.")

        if args.check_only:
            ok("Check-only mode: environment looks ready to build.")
            return 0

        if args.generate_only:
            do_generate(cfg)
            ok(f"Generated: {cfg.output_dir / (cfg.product_name + '.xcodeproj')}")
            return 0

        # `build` already runs generate internally, but we call generate first
        # so a generation failure is reported cleanly before xcodebuild starts.
        do_generate(cfg)
        do_build(cfg, args.configuration, args.destination, args.install)

        if args.install and args.launch_device:
            do_launch(cfg, args.launch_device)

        ok("Done.")
        return 0

    except BuildError as e:
        print(f"\n\033[1;31mERROR:\033[0m {e}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as e:
        print(f"\n\033[1;31mCommand failed (exit {e.returncode}):\033[0m "
              f"{e.cmd}", file=sys.stderr)
        return e.returncode


if __name__ == "__main__":
    raise SystemExit(main())
