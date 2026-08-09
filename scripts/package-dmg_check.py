#!/usr/bin/env python3
"""Focused regression checks for package-dmg architecture and Host sealing.

Exercises only file-layout/signing boundaries. It never invokes Swift, creates a
DMG, or runs a real codesign/lipo command.
"""

from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "scripts/package-dmg.py"
TESTS = 0


class CheckFailure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    global TESTS
    if not condition:
        raise CheckFailure(message)
    TESTS += 1


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise CheckFailure(f"cannot load {path.name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def check_signed_host_package(module) -> None:
    """The sealed package must be created from a signed copy, never the build product."""
    config = module.stable_host.load_config(ROOT)
    events: list[str] = []

    with tempfile.TemporaryDirectory(prefix="package-dmg-host-sign-check.") as temporary:
        work = Path(temporary)
        binary_root = work / "build"
        source_host = binary_root / config["entrypoint"]
        resource_bundle = binary_root / config["resourceBundle"]
        source_host.parent.mkdir(parents=True)
        resource_bundle.mkdir()
        source_host.write_bytes(b"universal host build product")
        original_source = source_host.read_bytes()
        signed_host = work / "signed-native-host" / config["entrypoint"]
        host_package = work / "host-package" / f"LinkDigestNativeHost-{config['productVersion']}-macos-arm64"

        original_run = module.run
        original_create = module.stable_host.create_package
        original_verify = module.stable_host.verify_package

        def fake_run(*command: str, cwd: Path | None = None) -> None:
            del cwd
            if command[1] == "--force":
                check(
                    command == (
                        "/usr/bin/codesign", "--force", "--sign", "-", "--identifier",
                        config["hostName"], str(signed_host),
                    ),
                    "Host signing must use the exact ad-hoc canonical identifier argv",
                )
                check(signed_host.read_bytes() == original_source, "signing must operate on a copied Host before mutation")
                signed_host.write_bytes(original_source + b".signed")
                events.append("sign")
                return
            check(
                command == ("/usr/bin/codesign", "--verify", "--strict", str(signed_host)),
                "signed Host must receive strict codesign verification",
            )
            check(signed_host.read_bytes().endswith(b".signed"), "strict verification must follow Host signing")
            events.append("codesign-verify")

        def fake_create(host: Path, bundle: Path, package: Path, root: Path) -> None:
            check(host == signed_host, "create_package must receive the signed Host copy")
            check(host.read_bytes().endswith(b".signed"), "create_package input must be the signed Host bytes")
            check(host != source_host, "create_package must never receive the unmodified build product")
            check(bundle == resource_bundle and package == host_package and root == ROOT, "create_package arguments must preserve canonical package inputs")
            events.append("create-package")

        def fake_verify(package: Path, root: Path) -> object:
            check(package == host_package and root == ROOT, "created Host package must remain strictly verified")
            events.append("verify-package")
            return object()

        module.run = fake_run
        module.stable_host.create_package = fake_create
        module.stable_host.verify_package = fake_verify
        try:
            result = module.create_host_package(binary_root, work, config)
        finally:
            module.run = original_run
            module.stable_host.create_package = original_create
            module.stable_host.verify_package = original_verify

        check(result == host_package, "create_host_package must return the sealed package root")
        check(source_host.read_bytes() == original_source, "native Host build product must not be modified by signing")
        check(events == ["sign", "codesign-verify", "create-package", "verify-package"], "Host must sign and strictly verify before package sealing")


def check_thinned_app_and_final_seal(module) -> None:
    """Only the App is thinned; Host stays sealed through the final app signature."""
    config = module.stable_host.load_config(ROOT)
    host_name = f"LinkDigestNativeHost-{config['productVersion']}-macos-arm64"
    events: list[str] = []

    with tempfile.TemporaryDirectory(prefix="package-dmg-thin-check.") as temporary:
        work = Path(temporary)
        source_app = work / "汲作.app"
        source_executable = source_app / "Contents/MacOS/LinkDigestApp"
        source_host_root = source_app / "Contents/Resources/NativeHost" / host_name
        source_host = source_host_root / config["entrypoint"]
        source_executable.parent.mkdir(parents=True)
        source_host_root.mkdir(parents=True)
        source_executable.write_bytes(b"universal app binary")
        source_host.write_bytes(b"universal signed host binary")
        (source_host_root / "SHA256SUMS").write_text("host-digest\n", encoding="utf-8")
        (source_host_root / "package.json").write_text(
            '{"architectures":["arm64","x86_64"]}\n', encoding="utf-8"
        )
        original_host_bytes = source_host.read_bytes()
        original_checksums = (source_host_root / "SHA256SUMS").read_bytes()
        original_metadata = (source_host_root / "package.json").read_bytes()
        destination = work / "arm64/汲作.app"
        destination_executable = destination / "Contents/MacOS/LinkDigestApp"
        destination_host_root = destination / "Contents/Resources/NativeHost" / host_name

        original_run = module.run
        original_check_output = module.subprocess.check_output
        original_verify = module.stable_host.verify_package
        original_sign_release = module.sign_release

        def fake_run(*command: str, cwd: Path | None = None) -> None:
            del cwd
            check(command[:2] == ("/usr/bin/lipo", str(destination_executable)), "only the main app executable may be passed to lipo")
            check(command[2:5] == ("-thin", "arm64", "-output"), "main app must be thinned for the requested architecture")
            shutil.copyfile(command[1], command[5])
            events.append("lipo")

        def fake_check_output(command: list[str], *, text: bool) -> str:
            check(text is True, "architecture inspection must request text output")
            check(command == ["/usr/bin/lipo", "-archs", str(destination_executable)], "only the thinned main app executable may be inspected")
            events.append("archs")
            return "arm64\n"

        def fake_verify(package: Path, root: Path) -> object:
            check(package == destination_host_root, "verify_package must receive the copied NativeHost package root")
            check(root == ROOT, "verify_package must use the repository root")
            check(package.joinpath(config["entrypoint"]).read_bytes() == original_host_bytes, "NativeHost executable must remain universal and byte-identical")
            check(package.joinpath("SHA256SUMS").read_bytes() == original_checksums, "NativeHost SHA256SUMS must remain unchanged")
            check(package.joinpath("package.json").read_bytes() == original_metadata, "NativeHost package metadata must remain unchanged")
            events.append("verify-package")
            return object()

        def fake_sign_release(app: Path, bundle_identifier: str) -> None:
            check(app == destination, "final app signature must target the thinned app")
            check(isinstance(bundle_identifier, str) and bundle_identifier, "final app signature requires its bundle identifier")
            events.append("sign-release")

        module.run = fake_run
        module.subprocess.check_output = fake_check_output
        module.stable_host.verify_package = fake_verify
        module.sign_release = fake_sign_release
        try:
            result = module.thin_app(source_app, destination, "arm64")
            module.sign_and_verify_app(destination, "com.syc.linkdigest", config)
        finally:
            module.run = original_run
            module.subprocess.check_output = original_check_output
            module.stable_host.verify_package = original_verify
            module.sign_release = original_sign_release

        check(result == destination, "thin_app must return the copied app destination")
        check(destination_executable.read_bytes() == b"universal app binary", "main app executable must be replaced by its requested architecture slice")
        check(destination_host_root.joinpath(config["entrypoint"]).read_bytes() == original_host_bytes, "NativeHost must not be lipo-thinned or replaced")
        check(events == ["lipo", "archs", "verify-package", "sign-release", "verify-package"], "Host must be verified after thinning and again after final app signing")


def main() -> int:
    module = load_module("package_dmg", TARGET)
    check_signed_host_package(module)
    check_thinned_app_and_final_seal(module)
    print(f"package-dmg-check: PASS ({TESTS} assertions)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CheckFailure as error:
        print(f"package-dmg-check: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
