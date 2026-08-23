#!/usr/bin/env python3
"""Build LinkDigest and atomically replace the two local daily-use artifacts.

This is deliberately a local deployment helper, not a DMG/release pipeline.
It builds the frozen Swift/Native-Host layout and WXT extension, then swaps
only the explicit App and unpacked-extension destinations after every build
step succeeds. No browser profile, manifest, credential, or user database is
read or written.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
# 用当前用户的家目录，不写死某一台机器的路径。
#
# 原来这里是 /Users/song/Applications：仓库一旦公开，它既暴露了本机用户名，
# 也让任何其他人克隆下来直接不可用——脚本会去写一个在他们机器上不存在的目录。
# `~/Applications` 是 macOS 的标准用户级应用目录，对每个用户都成立。
DEFAULT_APPLICATIONS = Path.home() / "Applications"
DEFAULT_APP: Path | None = None  # 在 main() 里按 release_unit.APP_BUNDLE 解析
DEFAULT_EXTENSION = DEFAULT_APPLICATIONS / "LinkDigest-extension-0.2.0"
NATIVE_HOST_SCRIPTS = ROOT / "scripts/native-host"

# release_unit imports its sibling stable_host by name when used in the
# release pipeline; make that same local module path explicit here.
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


def run(*command: str, cwd: Path = ROOT, env: dict[str, str] | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, env=env)


def output(
    command: list[str], cwd: Path = ROOT, env: dict[str, str] | None = None
) -> str:
    return subprocess.check_output(command, cwd=cwd, text=True, env=env).strip()


def swift_build_environment() -> dict[str, str]:
    """Use the caller's Xcode, or the validated full Xcode used by release builds."""
    environment = os.environ.copy()
    if not environment.get("DEVELOPER_DIR"):
        environment["DEVELOPER_DIR"] = release_unit.validate_full_xcode_developer_dir(
            release_unit.XCODE_DEVELOPER_DIR
        )
    return environment


def require_real_existing_directory(path: Path, label: str) -> None:
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        raise RuntimeError(f"{label} must be an existing real absolute directory: {path}")


def require_replaceable_destination(path: Path, label: str) -> None:
    require_real_existing_directory(path.parent, f"{label} parent")
    if not path.exists() or path.is_symlink() or not path.is_dir():
        raise RuntimeError(f"{label} must be the existing real directory selected for replacement: {path}")


def atomic_replace(staged: Path, destination: Path) -> None:
    previous = destination.with_name(f".{destination.name}.previous-{uuid.uuid4().hex}")
    os.replace(destination, previous)
    try:
        os.replace(staged, destination)
    except BaseException:
        os.replace(previous, destination)
        raise
    shutil.rmtree(previous)


def sign_ad_hoc(path: Path, identifier: str, *, bundle: bool) -> None:
    # The local product is a development artifact. This is not Developer ID
    # signing and never performs notarization or public release work.
    run(
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        "--identifier",
        identifier,
        str(path),
    )
    verify = [
        "/usr/bin/codesign",
        "--verify",
        "--strict",
        "--all-architectures",
        "--verbose=2",
        str(path),
    ]
    run(*verify)
    if bundle:
        run(*verify[:-1], "--deep", str(path))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-destination", type=Path, default=DEFAULT_APP)
    parser.add_argument("--extension-destination", type=Path, default=DEFAULT_EXTENSION)
    parser.add_argument("--replace", action="store_true", help="permit replacement of the two explicit existing destinations")
    parser.add_argument(
        "--skip-extension",
        action="store_true",
        help="build and deploy only the App, leaving the installed extension untouched",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    # `.app` 的文件名就是 Dock 和 Finder 显示的名字。它的真相源是 release_unit
    # 的 `APP_BUNDLE`——那份冻结清单，而不是 app-release.json。
    #
    # 两者的值必然相同（`load_app_config` 会拒绝对不上的 config），但方向不能反：
    # 冻结清单是**闸门**，config 是被它检查的输入。改名要改两处正是这道闸门的用途，
    # 跟 bundleIdentifier、executable 一样——把它改成「跟着 config 走」，
    # 校验就退化成拿 config 跟自己比。
    default_app = DEFAULT_APPLICATIONS / release_unit.APP_BUNDLE
    app_destination = (args.app_destination or default_app).resolve(strict=False)
    extension_destination = args.extension_destination.resolve(strict=False)
    if not args.replace:
        raise RuntimeError("refusing to replace daily-use artifacts without --replace")
    require_replaceable_destination(app_destination, "App destination")
    if not args.skip_extension:
        require_replaceable_destination(extension_destination, "Extension destination")

    # 扩展没改动时不必重建它。App 和扩展是两个独立产物，把它们绑死意味着每次
    # 只改 Swift 的部署都要多跑一遍 WXT；而 WXT 那条链依赖的 pnpm 版本一旦与
    # 本机不符，一个根本不碰扩展的 App 改动就完全无法部署。
    if not args.skip_extension:
        run("pnpm", "--config.verifyDepsBeforeRun=false", "browser:build")
    run("/bin/bash", "scripts/sync-contracts.sh")
    # universal 构建：每个 `--arch` 出一份切片，SwiftPM 再 lipo 成一个二进制。
    # 少了 x86_64 的话，2020 年前的 Intel Mac 下载后完全跑不起来。
    # 注意产物目录会因此变成 `.build/apple/Products/Release`，不再是
    # `.build/<arch>-apple-macosx/release`，所以路径一律问 `--show-bin-path`。
    build_flags = [
        "--package-path", str(ROOT / "apps/desktop"),
        "--configuration", "release",
        "--disable-sandbox", "--disable-netrc", "--skip-update",
    ]
    for architecture in stable_host.SUPPORTED_ARCHITECTURES:
        build_flags += ["--arch", architecture]
    swift_environment = swift_build_environment()
    run("swift", "build", *build_flags, env=swift_environment)
    binary_root = Path(output(
        ["swift", "build", *build_flags, "--show-bin-path"],
        env=swift_environment,
    ))

    # /tmp is a macOS symlink to /private/tmp. The Host packager deliberately
    # rejects any symlink ancestor, so select the canonical directory itself.
    with tempfile.TemporaryDirectory(prefix="linkdigest-local-deploy.", dir="/private/tmp") as temporary:
        work = Path(temporary)
        config = json.loads((ROOT / "config/native-host.json").read_text(encoding="utf-8"))
        app_config = release_unit.load_app_config(ROOT)
        # 目录名沿用 `-macos-arm64`，尽管二进制已经是 universal。
        #
        # 这个名字被浏览器的 Native Messaging manifest 以绝对路径写死，改名会让
        # 已安装的扩展立刻找不到 Host。架构的真相源是 config 与二进制本身
        # （`lipo -archs` 可查），不是这个目录名，所以不值得为了名字好看去换取
        # 一次全体用户重装。release_unit.py 里的固定名也与此保持一致。
        signed_host = work / "signed-host" / config["entrypoint"]
        signed_host.parent.mkdir(mode=0o700)
        shutil.copy2(binary_root / config["entrypoint"], signed_host)
        # Resources/NativeHost is not nested-code territory to codesign. Sign
        # before packaging so SHA256SUMS seals the signed bytes.
        sign_ad_hoc(signed_host, config["hostName"], bundle=False)

        host_package = work / "host-package" / f"LinkDigestNativeHost-{config['productVersion']}-macos-arm64"
        host_package.parent.mkdir(mode=0o700)
        stable_host.create_package(
            signed_host,
            binary_root / config["resourceBundle"],
            host_package,
            ROOT,
        )
        stable_host.verify_package(host_package, ROOT)

        staged_app = work / release_unit.APP_BUNDLE
        release_unit.build_app_bundle(
            staged_app,
            binary_root / app_config["executable"],
            binary_root / config["resourceBundle"],
            host_package,
            app_config,
            ROOT,
        )
        # The existing structural verifier intentionally validates an unsigned
        # assembly (the public release pipeline signs in a later sealed step).
        # Verify that exact layout first, then ad-hoc sign the local copy.
        release_unit.verify_app(staged_app, None, ROOT, app_config)
        sign_ad_hoc(staged_app, app_config["bundleIdentifier"], bundle=True)
        embedded_host_package = staged_app / "Contents/Resources/NativeHost" / host_package.name
        # The outer App signature must not mutate or invalidate the already
        # sealed Host package.
        stable_host.verify_package(embedded_host_package, ROOT)
        run(
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "--all-architectures",
            "--verbose=2",
            str(embedded_host_package / config["entrypoint"]),
        )

        extension_staging = None
        if not args.skip_extension:
            staged_extension = work / "LinkDigest-extension-0.2.0"
            extension_source = ROOT / "apps/browser-extension/.output/chrome-mv3"
            if extension_source.is_symlink() or not extension_source.is_dir():
                raise RuntimeError("WXT did not produce a real Chromium extension directory")
            shutil.copytree(extension_source, staged_extension, symlinks=False)
            manifest = json.loads((staged_extension / "manifest.json").read_text(encoding="utf-8"))
            if manifest.get("version") != "0.2.0":
                raise RuntimeError("built extension version does not match the daily-use destination")
            extension_staging = extension_destination.parent / f".{extension_destination.name}.staging-{uuid.uuid4().hex}"
            shutil.copytree(staged_extension, extension_staging, symlinks=False)

        app_staging = app_destination.parent / f".{app_destination.name}.staging-{uuid.uuid4().hex}"
        # Sparkle.framework is a versioned framework whose top-level entries
        # are symlinks into Versions/Current. Dereferencing them here changes
        # the signed bundle after verification and makes the installed App
        # fail `codesign --verify --deep --strict` even though `staged_app`
        # was valid. Preserve the already-verified framework layout exactly.
        shutil.copytree(staged_app, app_staging, symlinks=True)
        run(
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            "--all-architectures",
            "--verbose=2",
            str(app_staging),
        )
        try:
            atomic_replace(app_staging, app_destination)
            if extension_staging is not None:
                atomic_replace(extension_staging, extension_destination)
        finally:
            shutil.rmtree(app_staging, ignore_errors=True)
            if extension_staging is not None:
                shutil.rmtree(extension_staging, ignore_errors=True)

    print(f"deployed App: {app_destination}")
    if args.skip_extension:
        print("skipped extension: 未构建、未替换（--skip-extension）")
    else:
        print(f"deployed extension: {extension_destination}")
        print("Next: reload LinkDigest in Brave's extensions page, then use Browser Support in the App when needed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError, stable_host.StableHostError, release_unit.ReleaseUnitError) as error:
        print(f"local deployment failed: {error}", file=sys.stderr)
        raise SystemExit(1)
