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
        source_framework = source_app / "Contents/Frameworks/Sparkle.framework"
        source_framework_binary = source_framework / "Versions/B/Sparkle"
        source_executable.parent.mkdir(parents=True)
        source_host_root.mkdir(parents=True)
        source_framework_binary.parent.mkdir(parents=True)
        source_executable.write_bytes(b"universal app binary")
        source_host.write_bytes(b"universal signed host binary")
        source_framework_binary.write_bytes(b"universal sparkle binary")
        (source_framework / "Versions/Current").symlink_to("B")
        (source_framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
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
        destination_framework = destination / "Contents/Frameworks/Sparkle.framework"

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

        def fake_sign_release(
            app: Path,
            bundle_identifier: str,
            signing_identity: str | None = None,
        ) -> None:
            check(app == destination, "final app signature must target the thinned app")
            check(isinstance(bundle_identifier, str) and bundle_identifier, "final app signature requires its bundle identifier")
            check(signing_identity is None, "default package check must keep ad-hoc signing")
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
        check(
            destination_framework.joinpath("Versions/Current").is_symlink()
            and destination_framework.joinpath("Versions/Current").readlink() == Path("B")
            and destination_framework.joinpath("Sparkle").is_symlink()
            and destination_framework.joinpath("Sparkle").readlink() == Path("Versions/Current/Sparkle"),
            "Sparkle.framework versioned symlinks must survive architecture thinning",
        )
        check(events == ["lipo", "archs", "verify-package", "sign-release", "verify-package"], "Host must be verified after thinning and again after final app signing")


def check_dmg_signing_metadata_cleanup(module) -> None:
    """DMG layout cleanup must stay narrow and end in a deep strict verification."""
    with tempfile.TemporaryDirectory(prefix="package-dmg-xattr-check.") as temporary:
        app = Path(temporary) / "汲作.app"
        framework = app / "Contents/Frameworks/Sparkle.framework"
        framework.mkdir(parents=True)
        subprocess_run = module.subprocess.run
        subprocess_run(
            ["/usr/bin/xattr", "-w", "-x", "com.apple.FinderInfo", "00" * 32, str(framework)],
            check=True,
        )
        subprocess_run(
            ["/usr/bin/xattr", "-w", "com.linkdigest.keep", "keep", str(framework)],
            check=True,
        )
        module.remove_forbidden_signing_metadata(app)
        attributes = subprocess_run(
            ["/usr/bin/xattr", "-l", str(framework)],
            check=True,
            stdout=module.subprocess.PIPE,
        ).stdout
        check(b"com.apple.FinderInfo" not in attributes, "FinderInfo must be removed")
        check(b"com.linkdigest.keep" in attributes, "unrelated metadata must remain")

        calls: list[tuple[str, ...]] = []
        original_run = module.run

        def fake_run(*command: str, cwd: Path | None = None) -> None:
            check(cwd is None, "DMG metadata cleanup must not depend on a caller cwd")
            calls.append(command)

        module.run = fake_run
        try:
            module.remove_forbidden_signing_metadata_and_verify(app)
        finally:
            module.run = original_run

        check(
            calls == [
                ("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)),
            ],
            "DMG cleanup must end in one deep strict signature verification",
        )


def check_distribution_signing_and_notarization(module) -> None:
    identity = "Developer ID Application: Example (ABCDE12345)"
    profile = "jizuo-notary"
    check(
        module.distribution_signing(identity, profile) == (identity, profile),
        "paired Developer ID and Keychain profile must enable distribution signing",
    )
    check(
        module.release_signing_mode(True, None, None) == (None, None),
        "ad-hoc mode must remain an explicit local-test choice",
    )
    check(
        module.release_signing_mode(False, identity, profile) == (identity, profile),
        "distribution mode must require the complete Developer ID pair",
    )
    for invalid_mode in ((False, None, None), (True, identity, profile)):
        try:
            module.release_signing_mode(*invalid_mode)
        except RuntimeError:
            pass
        else:
            raise CheckFailure("ambiguous release signing mode was accepted")
    for invalid in ((identity, None), (None, profile), ("Apple Development: Example", profile)):
        try:
            module.distribution_signing(*invalid)
        except RuntimeError:
            pass
        else:
            raise CheckFailure("incomplete or non-Developer-ID distribution credentials were accepted")

    with tempfile.TemporaryDirectory(prefix="package-dmg-notary-check.") as temporary:
        root = Path(temporary)
        app = root / "汲作.app"
        app.mkdir()
        dmg = root / "汲作.dmg"
        dmg.write_bytes(b"dmg")
        calls: list[tuple[str, ...]] = []
        original_run = module.run

        def fake_run(*command: str, cwd: Path | None = None, env=None) -> None:
            check(cwd is None and env is None, "signing and notarization must not inherit a custom execution context")
            calls.append(command)

        module.run = fake_run
        try:
            module.sign_release(app, "com.syc.linkdigest", identity)
            module.notarize_and_staple_app(app, root / "app-notary", profile)
            module.sign_notarize_and_staple_dmg(dmg, identity, profile)
        finally:
            module.run = original_run

        check(
            calls[0] == (
                "/usr/bin/codesign", "--force", "--deep", "--options", "runtime",
                "--timestamp", "--sign", identity, "--identifier", "com.syc.linkdigest",
                str(app),
            ),
            "distribution App signing must use Developer ID, hardened runtime, and timestamp",
        )
        check(
            calls[2][0:3] == ("/usr/bin/ditto", "-c", "-k")
            and calls[3] == (
                "/usr/bin/xcrun", "notarytool", "submit",
                str(root / "app-notary/app-for-notarization.zip"),
                "--keychain-profile", profile, "--wait",
            ),
            "App notarization must submit a sealed ZIP through the named Keychain profile",
        )
        check(
            ("/usr/bin/xcrun", "stapler", "validate", str(app)) in calls
            and ("/usr/bin/xcrun", "stapler", "validate", str(dmg)) in calls,
            "App and DMG must both receive stapling validation",
        )
        check(
            calls[-1] == (
                "/usr/sbin/spctl", "--assess", "--type", "open", "--context",
                "context:primary-signature", "--verbose=2", str(dmg),
            ),
            "the notarized DMG must finish with a Gatekeeper assessment",
        )

    check(
        "不需要关闭 Gatekeeper" in module.install_note("汲作", True),
        "notarized builds need ordinary installation guidance",
    )
    check(
        "无法验证开发者" in module.install_note("汲作", False),
        "ad-hoc builds must keep their Gatekeeper warning",
    )


def check_chinese_bundle_localization(module) -> None:
    """The shipped Chinese app must not make AppKit panels fall back to English."""
    config = module.release_unit.load_app_config(ROOT)
    plist = module.release_unit.info_plist(config)
    check(plist["CFBundleDevelopmentRegion"] == "zh-Hans", "development region must be Simplified Chinese")
    check(plist["CFBundleLocalizations"] == ["zh-Hans"], "bundle must explicitly advertise Simplified Chinese")


def check_browser_extension_public_version(module) -> None:
    unit = module.release_unit
    app_config = unit.load_app_config(ROOT)
    _, manifest = unit.verified_browser_extension_payloads(ROOT)
    check(
        manifest["version_name"] == app_config["shortVersion"],
        "packaging must bind the extension public version to the App version",
    )

    drifted_config = dict(app_config)
    drifted_config["shortVersion"] = "0.2.25"
    original_load_app_config = unit.load_app_config
    unit.load_app_config = lambda _root=None: drifted_config
    try:
        try:
            unit.verified_browser_extension_payloads(ROOT)
        except unit.ReleaseUnitError as error:
            check(
                error.code == unit.INVALID_UNSAFE and "version_name" in str(error),
                "packaging must reject a stale extension public version",
            )
        else:
            raise CheckFailure("packaging accepted a stale extension public version")
    finally:
        unit.load_app_config = original_load_app_config


def check_sparkle_runtime_link_contract(module) -> None:
    """A signed App must still teach dyld where the embedded framework lives."""
    unit = module.release_unit
    executable = Path("/private/tmp/fixture/汲作.app/Contents/MacOS/LinkDigestApp")
    rpaths = ["/usr/lib/swift", "@executable_path/../lib"] * 2
    calls: list[tuple[list[str], set[str] | None]] = []
    original_architectures = unit.macho_architectures
    original_rpaths = unit.macho_rpaths
    original_libraries = unit.macho_linked_libraries
    original_command_ok = unit.command_ok

    unit.macho_architectures = lambda _path: ["x86_64", "arm64"]
    unit.macho_rpaths = lambda _path: list(rpaths)
    unit.macho_linked_libraries = lambda _path: [unit.SPARKLE_INSTALL_NAME] * 2

    def fake_command_ok(argv, **kwargs):
        calls.append((list(argv), kwargs.get("allowed")))
        rpaths.extend([unit.SPARKLE_RUNTIME_RPATH] * 2)
        return object()

    unit.command_ok = fake_command_ok
    try:
        unit.ensure_sparkle_runtime_rpath(executable)
        unit.verify_sparkle_runtime_link(executable)
        unit.ensure_sparkle_runtime_rpath(executable)
    finally:
        unit.macho_architectures = original_architectures
        unit.macho_rpaths = original_rpaths
        unit.macho_linked_libraries = original_libraries
        unit.command_ok = original_command_ok

    check(
        calls == [
            ([unit.INSTALL_NAME_TOOL, "-add_rpath", unit.SPARKLE_RUNTIME_RPATH, str(executable)], {unit.INSTALL_NAME_TOOL})
        ],
        "Sparkle runtime rpath must be added once with the fixed install_name_tool argv",
    )


def main() -> int:
    module = load_module("package_dmg", TARGET)
    check_signed_host_package(module)
    check_thinned_app_and_final_seal(module)
    check_dmg_signing_metadata_cleanup(module)
    check_distribution_signing_and_notarization(module)
    check_chinese_bundle_localization(module)
    check_browser_extension_public_version(module)
    check_sparkle_runtime_link_contract(module)
    print(f"package-dmg-check: PASS ({TESTS} assertions)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CheckFailure as error:
        print(f"package-dmg-check: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
