#!/usr/bin/env python3
"""Build a standalone ad-hoc-signed Debug App without deploying it."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NATIVE_HOST_SCRIPTS = ROOT / "scripts/native-host"
sys.path.insert(0, str(NATIVE_HOST_SCRIPTS))


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path.name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


stable_host = load_module("stable_host", NATIVE_HOST_SCRIPTS / "stable_host.py")
release_unit = load_module("linkdigest_release_unit", NATIVE_HOST_SCRIPTS / "release_unit.py")

BUILD_ENV = os.environ.copy()
BUILD_HOME = Path("/private/tmp/linkdigest-debug-candidate-home")
BUILD_CACHE = Path("/private/tmp/linkdigest-debug-candidate-cache")
DEBUG_APPLICATION_SUPPORT_ROOT = Path(
    "/private/tmp/linkdigest-fastlane-debug/Application Support"
)
DEBUG_BUNDLE_IDENTIFIER = "com.syc.linkdigest.debug.fastlane"
DEBUG_APP_NAME = "LinkDigest Debug.app"
EXTENSION_OUTPUT = ROOT / "apps/browser-extension/.output/chrome-mv3"
EXTENSION_IDENTITY = ROOT / "config/extension-identity.json"
PRODUCT_DISPLAY = (
    ROOT / "apps/desktop/Sources/LinkDigestCore/Resources/product-display.json"
)
EXPECTED_EXTENSION_PERMISSIONS = [
    "activeTab",
    "scripting",
    "storage",
    "nativeMessaging",
]
BUILD_HOME.mkdir(mode=0o700, parents=True, exist_ok=True)
BUILD_CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)
DEBUG_APPLICATION_SUPPORT_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
BUILD_ENV.update({
    "HOME": str(BUILD_HOME),
    "CLANG_MODULE_CACHE_PATH": str(BUILD_CACHE / "clang"),
    "SWIFT_MODULECACHE_PATH": str(BUILD_CACHE / "swift"),
})


def run(*command: str) -> None:
    subprocess.run(command, cwd=ROOT, env=BUILD_ENV, check=True)


def output(command: list[str]) -> str:
    return subprocess.check_output(command, cwd=ROOT, env=BUILD_ENV, text=True).strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    # 日用部署默认写真实 ~/Library/Application Support/LinkDigest。
    # 隔离数据根（/private/tmp）只给 smoke/工程验证用：重启即清空，
    # 绝不能作为日用数据位置。
    parser.add_argument("--isolated-data", action="store_true")
    return parser.parse_args()


def load_json_object(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot read {path.relative_to(ROOT)}: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeError(f"{path.relative_to(ROOT)} must contain a JSON object")
    return value


def validate_extension_output(source: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise RuntimeError("WXT chrome-mv3 output is missing or is a symbolic link")
    manifest = load_json_object(source / "manifest.json")
    identity = load_json_object(EXTENSION_IDENTITY)
    product_display = load_json_object(PRODUCT_DISPLAY)
    expected = {
        "name": product_display.get("displayName"),
        "description": product_display.get("extensionDescription"),
        "version": identity.get("version"),
        "key": identity.get("manifestKey"),
        "permissions": EXPECTED_EXTENSION_PERMISSIONS,
    }
    for field, expected_value in expected.items():
        if manifest.get(field) != expected_value:
            raise RuntimeError(f"extension manifest {field} does not match canonical config")


def copy_tree_nofollow(source: Path, destination: Path) -> None:
    """Copy a real directory tree while rejecting every symbolic link."""
    if source.is_symlink() or not source.is_dir():
        raise RuntimeError(f"refusing non-directory extension source: {source}")
    destination.mkdir(mode=0o700)
    with os.scandir(source) as entries:
        for entry in entries:
            source_entry = Path(entry.path)
            destination_entry = destination / entry.name
            if entry.is_symlink():
                raise RuntimeError(f"extension output contains symbolic link: {entry.name}")
            if entry.is_dir(follow_symlinks=False):
                copy_tree_nofollow(source_entry, destination_entry)
                continue
            if not entry.is_file(follow_symlinks=False):
                raise RuntimeError(f"extension output contains unsupported entry: {entry.name}")
            descriptor = os.open(source_entry, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                with os.fdopen(descriptor, "rb", closefd=True) as source_stream:
                    descriptor = -1
                    with destination_entry.open("xb") as destination_stream:
                        shutil.copyfileobj(source_stream, destination_stream)
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
            mode = stat.S_IMODE(entry.stat(follow_symlinks=False).st_mode)
            destination_entry.chmod(mode)


def verify_delivery_directory(delivery: Path) -> None:
    names = sorted(entry.name for entry in delivery.iterdir())
    if names != [DEBUG_APP_NAME, "extension"]:
        raise RuntimeError("Debug delivery directory must contain only the Debug App and extension")
    validate_extension_output(delivery / "extension")


def build_swift_commands(
    config: dict, package_path: Path
) -> tuple[list[str], list[str]]:
    """Debug Swift build and show-bin-path commands, both carrying the
    canonical universal architectures.

    build 与 show-bin-path 必须携带完全相同的 --arch 集合：否则 SwiftPM 按
    本机默认架构构建/定位，产物不是 universal，会在 Host verify 阶段与
    canonical architectures 不一致而失败。
    """
    architectures = config["architectures"]
    if architectures != stable_host.SUPPORTED_ARCHITECTURES:
        raise RuntimeError(
            f"native Host architectures must be exactly "
            f"{stable_host.SUPPORTED_ARCHITECTURES}, got {architectures}"
        )
    arch_args = [
        argument
        for architecture in architectures
        for argument in ("--arch", architecture)
    ]
    base = [
        "swift", "build",
        "--package-path", str(package_path),
        "--configuration", "debug",
        "--disable-sandbox", "--disable-netrc", "--skip-update",
        *arch_args,
    ]
    return base, base + ["--show-bin-path"]


def main() -> int:
    args = parse_args()
    destination = args.output.resolve(strict=False)
    private_tmp = Path("/private/tmp").resolve()
    if destination.parent != private_tmp:
        raise RuntimeError("Debug candidate output must be a direct child of /private/tmp")
    if destination.exists() or destination.is_symlink():
        raise RuntimeError(f"refusing to overwrite existing candidate: {destination}")

    config = stable_host.load_config(ROOT)
    app_config = release_unit.load_app_config(ROOT)
    build_command, show_bin_path_command = build_swift_commands(
        config, ROOT / "apps/desktop"
    )

    run("pnpm", "--filter", "@linkdigest/browser-extension", "build")
    validate_extension_output(EXTENSION_OUTPUT)

    run(*build_command)
    binary_root = Path(output(show_bin_path_command))

    with tempfile.TemporaryDirectory(prefix="linkdigest-debug-candidate.", dir="/private/tmp") as temporary:
        work = Path(temporary)
        delivery = work / "delivery"
        delivery.mkdir(mode=0o700)
        copy_tree_nofollow(EXTENSION_OUTPUT, delivery / "extension")
        host_package = work / "host-package" / (
            f"LinkDigestNativeHost-{config['productVersion']}-macos-{config['architectures'][0]}"
        )
        host_package.parent.mkdir(mode=0o700)
        stable_host.create_package(
            binary_root / config["entrypoint"],
            binary_root / config["resourceBundle"],
            host_package,
            ROOT,
        )
        stable_host.verify_package(host_package, ROOT)

        staged_app = work / DEBUG_APP_NAME
        release_unit.build_app_bundle(
            staged_app,
            binary_root / app_config["executable"],
            binary_root / config["resourceBundle"],
            host_package,
            app_config,
            ROOT,
        )
        release_unit.verify_app(staged_app, None, ROOT, app_config)

        info_plist = staged_app / "Contents/Info.plist"
        with info_plist.open("rb") as stream:
            info = plistlib.load(stream)
        info["CFBundleIdentifier"] = DEBUG_BUNDLE_IDENTIFIER
        info["CFBundleDisplayName"] = "LinkDigest Debug"
        info["CFBundleName"] = "LinkDigest Debug"
        # Debug candidates are short-lived local verification artifacts. They
        # must not ask the tester to make a persistent update-policy choice or
        # contact the public release feed before the UI under test is visible.
        info["SUEnableAutomaticChecks"] = False
        if args.isolated_data:
            info["LSEnvironment"] = {
                "LINKDIGEST_SMOKE_APPLICATION_SUPPORT_ROOT": str(
                    DEBUG_APPLICATION_SUPPORT_ROOT
                ),
            }
        else:
            # 日用模式：确保产物不携带任何数据根覆盖，App 使用真实
            # Application Support 目录。
            info.pop("LSEnvironment", None)
        with info_plist.open("wb") as stream:
            plistlib.dump(info, stream, sort_keys=True)
        run(
            "/usr/bin/codesign", "--force", "--sign", "-",
            "--identifier", DEBUG_BUNDLE_IDENTIFIER,
            str(staged_app),
        )
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged_app))
        shutil.copytree(staged_app, delivery / DEBUG_APP_NAME, symlinks=False)
        verify_delivery_directory(delivery)

        # Create the user-named top-level directory only after every build and
        # validation succeeds. `exist_ok=False` is the final no-clobber gate.
        destination.mkdir(mode=0o700, parents=False, exist_ok=False)
        (delivery / DEBUG_APP_NAME).rename(destination / DEBUG_APP_NAME)
        (delivery / "extension").rename(destination / "extension")
        verify_delivery_directory(destination)

    print(destination)
    if args.isolated_data:
        print(f"isolated data root: {DEBUG_APPLICATION_SUPPORT_ROOT}")
    else:
        print("data root: real Application Support (daily mode)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        RuntimeError,
        subprocess.CalledProcessError,
        stable_host.StableHostError,
        release_unit.ReleaseUnitError,
    ) as error:
        print(f"Debug candidate build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
