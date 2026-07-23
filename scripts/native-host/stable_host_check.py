#!/usr/bin/env python3
"""Deterministic Loop 4 r1 check; leaves two named audit roots in system tmp."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
STABLE = ROOT / "scripts/native-host/stable_host.py"
EXTENSION_A = "a" * 32
EXTENSION_B = "b" * 32
SENTINEL = "LinkDigest clean-room session v1\n"
TESTS = 0


class CheckFailure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    global TESTS
    if not condition:
        raise CheckFailure(message)
    TESTS += 1


def run(
    command: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    expect_success: bool = True,
    expected_error: str | None = None,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if expect_success and result.returncode != 0:
        raise CheckFailure(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{result.stdout.decode(errors='replace')}{result.stderr.decode(errors='replace')}"
        )
    if not expect_success and result.returncode == 0:
        raise CheckFailure(f"command unexpectedly succeeded: {' '.join(command)}")
    if expected_error is not None:
        combined = result.stdout + result.stderr
        if expected_error.encode() not in combined:
            raise CheckFailure(
                f"failure did not contain {expected_error!r}: {' '.join(command)}\n"
                f"{combined.decode(errors='replace')}"
            )
    return result


def metadata_digest(root: Path) -> str:
    if not os.path.lexists(root):
        return hashlib.sha256(b"absent\n").hexdigest()
    digest = hashlib.sha256()
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        for name in ["."] + directories + files:
            path = Path(current) if name == "." else Path(current) / name
            info = path.lstat()
            relative = path.relative_to(root).as_posix() if path != root else "."
            kind = stat.S_IFMT(info.st_mode)
            digest.update(
                f"{relative}\0{kind}\0{stat.S_IMODE(info.st_mode)}\0{info.st_ino}\0{info.st_size}\0{info.st_mtime_ns}\n".encode()
            )
    return digest.hexdigest()


def copy_source(destination: Path) -> None:
    def ignore(directory: str, names: list[str]) -> set[str]:
        directory_path = Path(directory)
        ignored = {name for name in names if name in {".git", ".build", "node_modules", ".output", "DerivedData"}}
        if directory_path == ROOT:
            ignored.update(name for name in names if name in {"output", ".scatter"})
        if directory_path.name == "docs" and "evidence" in names:
            ignored.add("evidence")
        return ignored

    shutil.copytree(ROOT, destination, symlinks=False, ignore=ignore)
    check(not (destination / ".git").exists(), "clean source copied .git")
    check(not any(destination.rglob(".build")), "clean source copied .build")
    check(not any(destination.rglob("node_modules")), "clean source copied node_modules")
    check(not (destination / "docs/evidence").exists(), "clean source copied user evidence")


def create_clean_home(session: Path, suffix: str) -> Path:
    home = session / f"linkdigest-host-clean-room.{suffix}"
    home.mkdir(mode=0o700)
    return home


def installer_command(package: Path, session: Path, home: Path, *extra: str) -> list[str]:
    return [
        sys.executable,
        str(STABLE),
        "clean-room-install",
        "--package-root",
        str(package),
        "--session-root",
        str(session),
        "--home-root",
        str(home),
        *extra,
    ]


def verifier(package: Path, *, success: bool, error: str | None = None) -> None:
    run(
        [sys.executable, str(STABLE), "verify-package", "--package-root", str(package)],
        expect_success=success,
        expected_error=error,
    )
    check(True, f"verifier case failed to execute for {package.name}")


def clone_case(package: Path, audit_root: Path, name: str) -> Path:
    target = audit_root / "tamper-cases" / name
    target.parent.mkdir(mode=0o755, exist_ok=True)
    shutil.copytree(package, target, copy_function=shutil.copy2)
    return target


def framed_fixture() -> bytes:
    fixture = (ROOT / "contracts/fixtures/valid.json").read_bytes()
    return len(fixture).to_bytes(4, "little") + fixture


def assert_missing_bundle_fails(host: Path) -> None:
    result = subprocess.run(
        [str(host)],
        input=framed_fixture(),
        env={**os.environ, "LINKDIGEST_SOCKET_PATH": str(host.parent / "missing.sock")},
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    valid_frame = False
    if result.returncode == 0 and len(result.stdout) >= 4:
        length = int.from_bytes(result.stdout[:4], "little")
        valid_frame = 0 < length <= 4 * 1024 * 1024 and len(result.stdout) == length + 4
    check(not valid_frame, "Host without package bundle used a build-directory fallback")


def main() -> int:
    # Keep Darwin Unix socket paths below sun_path limits. /tmp resolves to the
    # canonical system temporary root /private/tmp on macOS.
    temp_root = Path("/tmp").resolve()
    build_audit = Path(tempfile.mkdtemp(prefix="linkdigest-stable-package-audit.", dir=temp_root)).resolve()
    clean_room = Path(tempfile.mkdtemp(prefix="linkdigest-host-clean-room.audit.", dir=temp_root)).resolve()
    sentinel = clean_room / ".linkdigest-clean-room-root"
    sentinel.write_text(SENTINEL, encoding="utf-8")
    sentinel.chmod(0o600)

    live_root = Path(os.environ.get("HOME", str(Path.home()))).expanduser() / "Library/Application Support/LinkDigest"
    live_before = metadata_digest(live_root)
    poison_root: Path | None = None

    print("stable-package-check: audit roots are intentionally retained")
    print(f"BUILD_AUDIT_ROOT={build_audit}")
    print(f"CLEAN_ROOM_AUDIT_ROOT={clean_room}")

    try:
        source = build_audit / "source copy 空 格"
        copy_source(source)

        grdb_checkout = ROOT / "apps/desktop/.build/checkouts/GRDB.swift"
        check((grdb_checkout / ".git").is_dir(), "offline GRDB checkout is unavailable")
        grdb_local = build_audit / "dependencies/GRDB.swift"
        grdb_local.parent.mkdir(mode=0o700)
        shutil.copytree(
            grdb_checkout,
            grdb_local,
            symlinks=True,
            ignore=shutil.ignore_patterns(".git", ".gitmodules", ".build", "SQLiteCustom", "CustomSQLite"),
        )
        check(not (grdb_local / ".git").exists(), "audit-local GRDB dependency copied Git metadata")
        desktop_manifest = source / "apps/desktop/Package.swift"
        manifest_text = desktop_manifest.read_text(encoding="utf-8")
        remote_dependency = '.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")'
        local_dependency = f'.package(path: "{grdb_local}")'
        check(manifest_text.count(remote_dependency) == 1, "clean-source GRDB dependency declaration drifted")
        desktop_manifest.write_text(manifest_text.replace(remote_dependency, local_dependency), encoding="utf-8")
        swift_config = build_audit / "swiftpm-config"
        swift_cache = build_audit / "swiftpm-cache"
        swift_home = build_audit / "build-home"
        swift_config.mkdir(mode=0o700)
        swift_cache.mkdir(mode=0o700)
        swift_home.mkdir(mode=0o700)
        check((grdb_local / "Package.swift").is_file(), "audit-local GRDB package is incomplete")

        output_root = build_audit / "release-output"
        build_env = {
            **os.environ,
            "HOME": str(swift_home),
            "LINKDIGEST_BUILD_HOME": str(swift_home),
            "LINKDIGEST_SWIFTPM_CONFIG_PATH": str(swift_config),
            "LINKDIGEST_SWIFTPM_CACHE_PATH": str(swift_cache),
            "LINKDIGEST_SWIFTPM_SCRATCH_PATH": str(source / "apps/desktop/.build"),
            "LINKDIGEST_MODULE_CACHE_PATH": str(build_audit / "module-cache"),
            "GIT_TERMINAL_PROMPT": "0",
        }
        run(
            [str(source / "scripts/build-release.sh"), "--output-root", str(output_root)],
            cwd=source,
            env=build_env,
        )
        package = output_root / "LinkDigestNativeHost-0.2.0-macos-arm64"
        verifier(package, success=True)

        moved_parent = clean_room / "Moved Package 空格 μ"
        moved_parent.mkdir(mode=0o755)
        moved_package = moved_parent / package.name
        shutil.move(package, moved_package)
        verifier(moved_package, success=True)
        check(moved_package.is_dir(), "package did not survive a Unicode/space move")

        source_build = source / "apps/desktop/.build"
        check(source_build.is_dir(), "clean-source build directory was not created")
        shutil.rmtree(source_build)
        check(not source_build.exists(), "clean-source build directory was not removed")

        host = moved_package / "LinkDigestNativeHost"
        smoke_env = {
            **os.environ,
            "LINKDIGEST_HOST_PACKAGE_ROOT": str(moved_package),
            "TMPDIR": str(ROOT),
        }
        run([str(ROOT / "scripts/run-host-smoke.sh")], env=smoke_env)
        check(True, "verified package-root Host smoke failed")
        run(
            [str(ROOT / "scripts/run-host-smoke.sh")],
            env={**os.environ, "LINKDIGEST_HOST_PATH": str(host), "LINKDIGEST_SKIP_BUILD": "1"},
            expect_success=False,
            expected_error="raw LINKDIGEST_HOST_PATH/LINKDIGEST_SKIP_BUILD overrides are forbidden",
        )
        check(True, "raw executable Host override was accepted")

        darwin_tmp_result = run(["getconf", "DARWIN_USER_TEMP_DIR"])
        darwin_tmp = Path(darwin_tmp_result.stdout.decode("utf-8").strip()).resolve()
        check(darwin_tmp.is_dir() and not str(darwin_tmp).startswith("/private/tmp/"), "Darwin user temp is not an outside-scope test root")
        poison_root = Path(tempfile.mkdtemp(prefix="linkdigest-host-clean-room.poison.", dir=darwin_tmp)).resolve()
        poison_home = poison_root / "linkdigest-host-clean-room.home"
        poison_home.mkdir(mode=0o700)
        (poison_root / ".linkdigest-clean-room-root").write_text(SENTINEL, encoding="utf-8")
        (poison_root / ".linkdigest-clean-room-root").chmod(0o600)
        poisoned_install = installer_command(
            moved_package,
            poison_root,
            poison_home,
            "--browser",
            "chrome",
            "--extension-id",
            EXTENSION_A,
            "--apply",
        )
        poison_before = metadata_digest(poison_root)
        for poisoned_tmpdir in (str(ROOT), str(Path(os.environ["HOME"]).resolve())):
            run(
                poisoned_install,
                env={**os.environ, "TMPDIR": poisoned_tmpdir},
                expect_success=False,
                expected_error="inside fixed canonical /private/tmp",
            )
            check(metadata_digest(poison_root) == poison_before, "poisoned TMPDIR clean-room rejection wrote outside /private/tmp")

        outside_socket = poison_root / "scope-outside.sock"
        run(
            [str(ROOT / "scripts/run-host-smoke.sh")],
            env={
                **os.environ,
                "LINKDIGEST_HOST_PACKAGE_ROOT": str(moved_package),
                "LINKDIGEST_HOST_SMOKE_SOCKET_PATH": str(outside_socket),
            },
            expect_success=False,
            expected_error="LINKDIGEST_HOST_SMOKE_SOCKET_PATH is forbidden",
        )
        check(not os.path.lexists(outside_socket), "scope-outside Host smoke socket was created")

        worktree_before_vertical = subprocess.run(
            ["git", "status", "--porcelain=v1", "-z"], cwd=ROOT, check=True, stdout=subprocess.PIPE
        ).stdout
        home_tmp_matches_before = set(Path(os.environ["HOME"]).glob("linkdigest-vertical-smoke.*"))
        poison_before_vertical = metadata_digest(poison_root)
        for poisoned_tmpdir in (str(ROOT), str(Path(os.environ["HOME"]).resolve())):
            run(
                [str(ROOT / "scripts/run-vertical-smoke.sh")],
                env={**os.environ, "TMPDIR": poisoned_tmpdir},
            )
        worktree_after_vertical = subprocess.run(
            ["git", "status", "--porcelain=v1", "-z"], cwd=ROOT, check=True, stdout=subprocess.PIPE
        ).stdout
        check(worktree_before_vertical == worktree_after_vertical, "poisoned TMPDIR vertical smoke changed worktree metadata")
        check(metadata_digest(poison_root) == poison_before_vertical, "poisoned TMPDIR vertical smoke wrote outside /private/tmp")
        check(
            set(Path(os.environ["HOME"]).glob("linkdigest-vertical-smoke.*")) == home_tmp_matches_before,
            "TMPDIR=HOME vertical smoke created a Home-level temporary root",
        )
        missing_bundle_dir = build_audit / "missing-bundle-runtime-probe"
        missing_bundle_dir.mkdir(mode=0o755)
        missing_host = missing_bundle_dir / host.name
        shutil.copy2(host, missing_host)
        missing_host.chmod(0o755)
        assert_missing_bundle_fails(missing_host)

        manifest = run(
            [
                sys.executable,
                str(STABLE),
                "render-manifest",
                "--mode",
                "test",
                "--host-path",
                str(host),
                "--extension-id",
                EXTENSION_B,
                "--extension-id",
                EXTENSION_A,
                "--extension-id",
                EXTENSION_B,
            ]
        )
        payload = json.loads(manifest.stdout)
        check(
            payload["allowed_origins"]
            == [f"chrome-extension://{EXTENSION_A}/", f"chrome-extension://{EXTENSION_B}/"],
            "manifest IDs were not sorted and deduplicated",
        )
        check(all("*" not in origin for origin in payload["allowed_origins"]), "manifest contains a wildcard origin")
        release_manifest = run(
            [
                sys.executable,
                str(STABLE),
                "render-manifest",
                "--mode",
                "release",
                "--host-path",
                str(host),
            ]
        )
        release_payload = json.loads(release_manifest.stdout)
        release_ids = json.loads((ROOT / "config/native-host.json").read_text(encoding="utf-8"))["releaseExtensionIDs"]
        check(
            release_payload["allowed_origins"] == [f"chrome-extension://{extension_id}/" for extension_id in release_ids],
            "release manifest did not bind canonical extension IDs",
        )
        check(len(release_payload["allowed_origins"]) == 1 and "*" not in release_payload["allowed_origins"][0], "release manifest origin was not one exact non-wildcard ID")
        run(
            [
                sys.executable,
                str(STABLE),
                "render-manifest",
                "--mode",
                "test",
                "--host-path",
                str(host),
                "--extension-id",
                "invalid",
            ],
            expect_success=False,
            expected_error="invalid Chromium extension ID",
        )
        check(True, "invalid test extension ID was accepted")

        home_default = create_clean_home(clean_room, "home-default")
        base_install = installer_command(
            moved_package,
            clean_room,
            home_default,
            "--browser",
            "chrome",
            "--browser",
            "brave",
            "--browser",
            "edge",
            "--extension-id",
            EXTENSION_B,
            "--extension-id",
            EXTENSION_A,
            "--extension-id",
            EXTENSION_B,
        )
        dry_before = metadata_digest(home_default)
        dry_result = run(base_install)
        dry_after = metadata_digest(home_default)
        dry_plan = json.loads(dry_result.stdout)
        check(dry_before == dry_after, "clean-room dry-run wrote files")
        expected_default_targets = {
            str(home_default / "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.syc.linkdigest.v01.json"),
            str(home_default / "Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.syc.linkdigest.v01.json"),
        }
        check(
            set(dry_plan["manifestTargets"]) == expected_default_targets,
            "Chrome and Brave did not share their exact active target, or Edge drifted",
        )
        run(base_install + ["--apply"])
        installed_before = metadata_digest(home_default)
        noop = run(base_install + ["--apply"])
        installed_after = metadata_digest(home_default)
        check(b"noop" in noop.stdout, "second identical apply was not a noop")
        check(installed_before == installed_after, "noop changed installed mtimes or metadata")

        extra_dir_home = create_clean_home(clean_room, "home-extra-directory")
        extra_dir_install = installer_command(
            moved_package,
            clean_room,
            extra_dir_home,
            "--browser",
            "chrome",
            "--extension-id",
            EXTENSION_A,
            "--apply",
        )
        run(extra_dir_install)
        extra_version = extra_dir_home / "Library/Application Support/LinkDigest/NativeMessagingHost/versions/0.2.0-macos-arm64"
        (extra_version / "unknown-empty-directory").mkdir(mode=0o700)
        run(extra_dir_install, expect_success=False, expected_error="version directory differs")
        check(True, "existing version with an extra empty directory was accepted")

        receipt_path = Path(dry_plan["receipt"])
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        check(
            set(receipt)
            == {"formatVersion", "hostName", "installedVersion", "packageDigest", "versionDirectory", "ownedManifests"},
            "receipt-v1 fields escaped the frozen boundary",
        )
        receipt_text = receipt_path.read_text(encoding="utf-8").lower()
        check(
            all(marker not in receipt_text for marker in ("api key", "apikey", "cookie", "token", "secret", EXTENSION_A, EXTENSION_B)),
            "receipt contains a secret-like field or extension ID",
        )
        check(
            len(receipt["ownedManifests"]) == 2
            and all(len(item["sha256"]) == 64 for item in receipt["ownedManifests"]),
            "receipt manifest ownership hashes are incomplete",
        )
        check(
            {item["path"] for item in receipt["ownedManifests"]} == expected_default_targets,
            "receipt manifest ownership paths do not use the shared Chrome/Brave target",
        )

        edge_home = create_clean_home(clean_room, "home-edge-profile")
        edge_profile = clean_room / "isolated Edge profile 空格"
        edge_profile.mkdir(mode=0o700)
        edge_install = installer_command(
            moved_package,
            clean_room,
            edge_home,
            "--browser",
            "edge",
            "--edge-user-data-dir",
            str(edge_profile),
            "--extension-id",
            EXTENSION_A,
            "--apply",
        )
        run(edge_install)
        edge_manifest = edge_profile / "NativeMessagingHosts/com.syc.linkdigest.v01.json"
        check(edge_manifest.is_file(), "isolated Edge manifest was not installed")
        check(edge_manifest.parent.parent == edge_profile, "isolated Edge manifest is not a direct profile child")

        outside_profile = build_audit / "outside-edge-profile"
        outside_profile.mkdir(mode=0o700)
        run(
            installer_command(
                moved_package,
                clean_room,
                create_clean_home(clean_room, "home-edge-reject"),
                "--browser",
                "edge",
                "--edge-user-data-dir",
                str(outside_profile),
                "--extension-id",
                EXTENSION_A,
            ),
            expect_success=False,
            expected_error="inside the clean-room session",
        )
        check(True, "out-of-scope Edge profile was accepted")

        unknown_home = create_clean_home(clean_room, "home-unknown-target")
        unknown_manifest = unknown_home / "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.syc.linkdigest.v01.json"
        unknown_manifest.parent.mkdir(parents=True, mode=0o700)
        unknown_manifest.write_text("unknown\n", encoding="utf-8")
        unknown_manifest.chmod(0o600)
        unknown_before = unknown_manifest.read_bytes()
        run(
            installer_command(
                moved_package,
                clean_room,
                unknown_home,
                "--browser",
                "chrome",
                "--extension-id",
                EXTENSION_A,
                "--apply",
            ),
            expect_success=False,
            expected_error="unknown or differs",
        )
        check(unknown_manifest.read_bytes() == unknown_before, "unknown target was overwritten")

        failure_home = create_clean_home(clean_room, "home-failure-injection")
        failure_manifest = failure_home / "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.syc.linkdigest.v01.json"
        failure_version = failure_home / "Library/Application Support/LinkDigest/NativeMessagingHost/versions/0.2.0-macos-arm64"
        failure_receipt = failure_home / "Library/Application Support/LinkDigest/NativeMessagingHost/receipt-v1.json"
        run(
            installer_command(
                moved_package,
                clean_room,
                failure_home,
                "--browser",
                "chrome",
                "--extension-id",
                EXTENSION_A,
                "--inject-failure",
                "after-manifest",
                "--apply",
            ),
            expect_success=False,
            expected_error="injected failure after manifest",
        )
        check(not os.path.lexists(failure_manifest), "failure rollback left a manifest")
        check(not os.path.lexists(failure_version), "failure rollback left a version directory")
        check(not os.path.lexists(failure_receipt), "failure rollback left a receipt")
        check(not list(failure_home.rglob(".staging-*")), "failure rollback left staging")

        real_home_attempt = installer_command(
            moved_package,
            clean_room,
            Path(os.environ["HOME"]).resolve(),
            "--browser",
            "chrome",
            "--extension-id",
            EXTENSION_A,
        )
        run(real_home_attempt, expect_success=False)
        check(True, "real HOME path gate did not reject")

        symlink_home = create_clean_home(clean_room, "home-symlink-reject")
        symlink_outside = build_audit / "install-symlink-outside"
        symlink_outside.mkdir(mode=0o700)
        outside_marker = symlink_outside / "marker"
        outside_marker.write_text("unchanged\n", encoding="utf-8")
        outside_marker.chmod(0o600)
        (symlink_home / "Library").symlink_to(symlink_outside)
        run(
            installer_command(
                moved_package,
                clean_room,
                symlink_home,
                "--browser",
                "chrome",
                "--extension-id",
                EXTENSION_A,
                "--apply",
            ),
            expect_success=False,
            expected_error="contains a symlink path component",
        )
        check(outside_marker.read_text(encoding="utf-8") == "unchanged\n", "symlink path gate wrote outside scope")

        checksum_case = clone_case(moved_package, build_audit, "checksum-drift")
        drift_file = checksum_case / "LinkDigest_LinkDigestCore.bundle/Resources/placeholder.txt"
        drift_file.write_bytes(drift_file.read_bytes() + b"drift")
        verifier(checksum_case, success=False, error="checksum drift detected")

        bundle_case = clone_case(moved_package, build_audit, "missing-bundle")
        shutil.rmtree(bundle_case / "LinkDigest_LinkDigestCore.bundle")
        verifier(bundle_case, success=False, error="top-level entries mismatch")

        schema_case = clone_case(moved_package, build_audit, "missing-schema")
        (schema_case / "LinkDigest_LinkDigestCore.bundle/Resources/contracts/capture-envelope-v1.schema.json").unlink()
        verifier(schema_case, success=False, error="contract schema is missing")

        permission_case = clone_case(moved_package, build_audit, "wrong-permission")
        (permission_case / "package.json").chmod(0o600)
        verifier(permission_case, success=False, error="permission mismatch")

        symlink_case = clone_case(moved_package, build_audit, "symlink-entry")
        (symlink_case / "LinkDigest_LinkDigestCore.bundle/escape").symlink_to("/private/tmp")
        verifier(symlink_case, success=False, error="contains a symlink")

        fifo_case = clone_case(moved_package, build_audit, "fifo-entry")
        os.mkfifo(fifo_case / "LinkDigest_LinkDigestCore.bundle/fifo", mode=0o644)
        verifier(fifo_case, success=False, error="non-regular entry")

        socket_case = clone_case(moved_package, build_audit, "socket-entry")
        socket_path = socket_case / "LinkDigest_LinkDigestCore.bundle/socket"
        short_socket_path = temp_root / f"ld-socket-tamper-{os.getpid()}"
        if os.path.lexists(short_socket_path):
            short_socket_path.unlink()
        unix_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            unix_socket.bind(str(short_socket_path))
        finally:
            unix_socket.close()
        os.rename(short_socket_path, socket_path)
        verifier(socket_case, success=False, error="non-regular entry")

        extra_case = clone_case(moved_package, build_audit, "extra-top-level")
        (extra_case / "EXTRA").write_text("extra\n", encoding="utf-8")
        (extra_case / "EXTRA").chmod(0o644)
        verifier(extra_case, success=False, error="top-level entries mismatch")

        metadata_case = clone_case(moved_package, build_audit, "metadata-host-drift")
        metadata = json.loads((metadata_case / "package.json").read_text(encoding="utf-8"))
        metadata["hostName"] = "com.invalid.host"
        (metadata_case / "package.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (metadata_case / "package.json").chmod(0o644)
        verifier(metadata_case, success=False, error="metadata does not match")

        live_after = metadata_digest(live_root)
        check(live_before == live_after, "real LinkDigest HOME metadata changed")
        print(f"stable-package-check: real HOME metadata unchanged (sha256 {live_after})")
        print(f"stable-package-check: PASS ({TESTS} assertions)")
        print("stable-package-check: two audit TMP directories intentionally remain for review")
        print(f"BUILD_AUDIT_ROOT={build_audit}")
        print(f"CLEAN_ROOM_AUDIT_ROOT={clean_room}")
        if poison_root is not None:
            shutil.rmtree(poison_root)
            poison_root = None
        return 0
    except BaseException as error:
        live_after = metadata_digest(live_root)
        print(f"stable-package-check: FAIL: {error}", file=sys.stderr)
        print(f"stable-package-check: real HOME metadata before={live_before} after={live_after}", file=sys.stderr)
        print(f"BUILD_AUDIT_ROOT={build_audit}", file=sys.stderr)
        print(f"CLEAN_ROOM_AUDIT_ROOT={clean_room}", file=sys.stderr)
        if poison_root is not None:
            shutil.rmtree(poison_root, ignore_errors=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
