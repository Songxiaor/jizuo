#!/usr/bin/env python3
"""Deterministic r4a gate; builds a real App/DMG and retains its audit root."""

from __future__ import annotations

import ast
import json
import os
import plistlib
import stat
import subprocess
import sys
import uuid
import argparse
from pathlib import Path
from typing import Any, Callable

sys.dont_write_bytecode = True

import release_unit as unit


ROOT = Path(__file__).resolve().parents[2]
TESTS = 0
REVIEW_PREFIX = "linkdigest-r4a-review."


class CheckFailure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    global TESTS
    if not condition:
        raise CheckFailure(message)
    TESTS += 1


def expect_error(action: Callable[[], Any], code: int, message: str) -> unit.ReleaseUnitError:
    try:
        action()
    except unit.ReleaseUnitError as error:
        check(error.code == code, f"{message}: expected exit {code}, got {error.code}")
        return error
    raise CheckFailure(f"{message}: unsafe case unexpectedly succeeded")


def canonical_file(path: Path, value: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(unit.canonical_bytes(value))
    os.chmod(path, mode)


def run(command: list[str], *, cwd: Path = ROOT, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=300,
        )
    except subprocess.TimeoutExpired as error:
        raise CheckFailure(f"command timed out: {' '.join(command)}") from error
    if result.returncode != 0:
        raise CheckFailure(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{(result.stdout + result.stderr).decode(errors='replace')[-4000:]}"
        )
    return result


def validate_new_review_root(value: str) -> Path:
    path = unit.validate_lexical_absolute(value, "--review-root")
    if path.parent != Path("/private/tmp") or not path.name.startswith(REVIEW_PREFIX) or len(path.name) <= len(REVIEW_PREFIX):
        raise CheckFailure(f"--review-root must be a new direct child named /private/tmp/{REVIEW_PREFIX}*")
    unit.assert_real_components(path.parent, "review root parent")
    if os.path.lexists(path):
        raise CheckFailure("--review-root must not already exist")
    return path


def swift_tests(audit: Path, review: Path) -> int:
    source = audit / "source"
    developer_dir = unit.validate_full_xcode_developer_dir(unit.XCODE_DEVELOPER_DIR)
    common = [
        "/usr/bin/swift",
        "test",
        "--package-path",
        str(source / "apps/desktop"),
        "--disable-sandbox",
        "--disable-netrc",
        "--skip-update",
        "--config-path",
        str(review / "test-swiftpm-config"),
        "--cache-path",
        str(review / "test-swiftpm-cache"),
        "--scratch-path",
        str(review / "swift-test-scratch"),
    ]
    for directory in (
        review / "test-home",
        review / "test-tmp",
        review / "test-module-cache",
        review / "test-swiftpm-config",
        review / "test-swiftpm-cache",
    ):
        directory.mkdir(mode=0o700, exist_ok=True)
    env = {
        "HOME": str(review / "test-home"),
        "TMPDIR": str(review / "test-tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "DEVELOPER_DIR": developer_dir,
        "CLANG_MODULE_CACHE_PATH": str(review / "test-module-cache"),
        "SWIFT_MODULECACHE_PATH": str(review / "test-module-cache"),
        "GIT_TERMINAL_PROMPT": "0",
    }
    result = run(common + ["--filter", "LinkDigestCoreTests.ContractTests"], cwd=source, env=env)
    combined = result.stdout + result.stderr
    check(b"Executed 11 tests, with 0 failures" in combined, "focused Swift ContractTests 11/11")
    return 11


def config_cases(cases: Path) -> None:
    config = unit.load_app_config(ROOT)
    check(config["architectures"] == unit.stable_host.SUPPORTED_ARCHITECTURES, "canonical app config")
    check(config["iconFile"] == unit.APP_ICON_FILE, "canonical App icon config")
    base = cases / "config"
    (base / "config").mkdir(parents=True)
    value = dict(config)
    value["extra"] = True
    canonical_file(base / "config/app-release.json", value)
    expect_error(lambda: unit.load_app_config(base), unit.INVALID_UNSAFE, "extra app config key")
    value = dict(config)
    value["formatVersion"] = True
    canonical_file(base / "config/app-release.json", value)
    expect_error(lambda: unit.load_app_config(base), unit.INVALID_UNSAFE, "bool app config version")
    value = dict(config)
    value["minimumMacOS"] = "14.0"
    canonical_file(base / "config/app-release.json", value)
    expect_error(lambda: unit.load_app_config(base), unit.INVALID_UNSAFE, "app config minimum drift")
    value = dict(config)
    value["iconFile"] = "OtherIcon.icns"
    canonical_file(base / "config/app-release.json", value)
    expect_error(lambda: unit.load_app_config(base), unit.INVALID_UNSAFE, "app config icon drift")


def fake_full_xcode(cases: Path, name: str) -> Path:
    developer = cases / name / "Xcode.app/Contents/Developer"
    required = (
        developer / "usr/bin/xcodebuild",
        developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
        developer.parent / "SharedFrameworks/XCBuild.framework/Versions/A/XCBuild",
    )
    for executable in required:
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("fixture\n", encoding="utf-8")
        os.chmod(executable, 0o755)
    return developer


def xcode_selection_cases(cases: Path) -> None:
    valid = fake_full_xcode(cases, "valid-full-xcode")
    check(unit.validate_full_xcode_developer_dir(valid) == str(valid), "fixed full Xcode structure accepted")

    missing = fake_full_xcode(cases, "missing-xcbuild")
    (missing.parent / "SharedFrameworks/XCBuild.framework/Versions/A/XCBuild").unlink()
    expect_error(
        lambda: unit.validate_full_xcode_developer_dir(missing),
        unit.ENVIRONMENT_BLOCKED,
        "incomplete full Xcode",
    )

    unsafe = fake_full_xcode(cases, "unsafe-xcode")
    xcodebuild = unsafe / "usr/bin/xcodebuild"
    xcodebuild.unlink()
    xcodebuild.symlink_to("/usr/bin/true")
    expect_error(
        lambda: unit.validate_full_xcode_developer_dir(unsafe),
        unit.INVALID_UNSAFE,
        "symlinked Xcode executable",
    )


def universal_build_argument_cases(cases: Path) -> None:
    source = cases / "universal-build-source"
    source.mkdir()
    audit = cases / "universal-build-audit"
    audit.mkdir()
    bin_path = cases / "universal-products"
    bin_path.mkdir()
    for name in ("LinkDigestApp", "LinkDigestNativeHost"):
        executable = bin_path / name
        executable.write_text("fixture\n", encoding="utf-8")
        os.chmod(executable, 0o755)
    (bin_path / unit.RESOURCE_BUNDLE).mkdir()

    calls: list[tuple[list[str], dict[str, Any]]] = []
    original = unit.command_ok
    original_developer_dir = unit.XCODE_DEVELOPER_DIR
    original_caller_developer_dir = os.environ.get("DEVELOPER_DIR")
    developer_dir = fake_full_xcode(cases, "build-full-xcode")

    def fake_command_ok(argv: list[str], **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
        calls.append((list(argv), kwargs))
        stdout = (str(bin_path) + "\n").encode("utf-8") if "--show-bin-path" in argv else b""
        return subprocess.CompletedProcess(argv, 0, stdout, b"")

    try:
        unit.command_ok = fake_command_ok
        unit.XCODE_DEVELOPER_DIR = developer_dir
        os.environ["DEVELOPER_DIR"] = "/caller/controlled/Xcode.app/Contents/Developer"
        products = unit.build_swift_products(
            source,
            audit,
            list(unit.stable_host.SUPPORTED_ARCHITECTURES),
        )
        check(products == (bin_path / "LinkDigestApp", bin_path / "LinkDigestNativeHost", bin_path / unit.RESOURCE_BUNDLE), "universal build products located")
        check(len(calls) == 2, "universal build runs build and show-bin-path")
        for argv, kwargs in calls:
            architecture_pairs = [
                (argv[index], argv[index + 1])
                for index in range(len(argv) - 1)
                if argv[index] == "--arch"
            ]
            check(
                architecture_pairs == [("--arch", "arm64"), ("--arch", "x86_64")],
                "SwiftPM argv carries exact universal architectures",
            )
            check(kwargs.get("allowed") == {unit.SWIFT} and kwargs.get("cwd") == source, "universal build command remains scoped")
            check(kwargs.get("env", {}).get("DEVELOPER_DIR") == str(developer_dir), "SwiftPM command uses validated fixed Xcode")
        expect_error(
            lambda: unit.build_swift_products(source, cases / "single-arch-audit", ["arm64"]),
            unit.INVALID_UNSAFE,
            "single-architecture build request",
        )
    finally:
        unit.command_ok = original
        unit.XCODE_DEVELOPER_DIR = original_developer_dir
        if original_caller_developer_dir is None:
            os.environ.pop("DEVELOPER_DIR", None)
        else:
            os.environ["DEVELOPER_DIR"] = original_caller_developer_dir


def swift_test_xcode_env_cases(cases: Path) -> None:
    audit = cases / "swift-test-audit"
    (audit / "source").mkdir(parents=True)
    review = cases / "swift-test-review"
    review.mkdir()
    developer_dir = fake_full_xcode(cases, "swift-test-full-xcode")
    calls: list[tuple[list[str], Path, dict[str, str]]] = []
    original_run = globals()["run"]
    original_developer_dir = unit.XCODE_DEVELOPER_DIR
    original_caller_developer_dir = os.environ.get("DEVELOPER_DIR")

    def fake_run(
        command: list[str],
        *,
        cwd: Path = ROOT,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[bytes]:
        calls.append((list(command), cwd, dict(env or {})))
        return subprocess.CompletedProcess(command, 0, b"Executed 11 tests, with 0 failures\n", b"")

    try:
        globals()["run"] = fake_run
        unit.XCODE_DEVELOPER_DIR = developer_dir
        os.environ["DEVELOPER_DIR"] = "/caller/controlled/Xcode.app/Contents/Developer"
        check(swift_tests(audit, review) == 11, "focused Swift test count returned")
        check(len(calls) == 1, "focused Swift gate invokes one scoped command")
        command, cwd, env = calls[0]
        check(
            command[0:2] == [unit.SWIFT, "test"]
            and command[-2:] == ["--filter", "LinkDigestCoreTests.ContractTests"],
            "focused Swift command remains exact",
        )
        check(cwd == audit / "source", "focused Swift command source root")
        check(env.get("DEVELOPER_DIR") == str(developer_dir), "focused Swift gate uses validated fixed Xcode")

        missing = fake_full_xcode(cases, "swift-test-missing-xcode")
        (missing / "usr/bin/xcodebuild").unlink()
        unit.XCODE_DEVELOPER_DIR = missing
        expect_error(
            lambda: swift_tests(audit, review),
            unit.ENVIRONMENT_BLOCKED,
            "focused Swift gate missing full Xcode",
        )

        unsafe = fake_full_xcode(cases, "swift-test-unsafe-xcode")
        xcodebuild = unsafe / "usr/bin/xcodebuild"
        xcodebuild.unlink()
        xcodebuild.symlink_to("/usr/bin/true")
        unit.XCODE_DEVELOPER_DIR = unsafe
        expect_error(
            lambda: swift_tests(audit, review),
            unit.INVALID_UNSAFE,
            "focused Swift gate unsafe full Xcode",
        )
        check(len(calls) == 1, "invalid Xcode rejected before invoking Swift")
    finally:
        globals()["run"] = original_run
        unit.XCODE_DEVELOPER_DIR = original_developer_dir
        if original_caller_developer_dir is None:
            os.environ.pop("DEVELOPER_DIR", None)
        else:
            os.environ["DEVELOPER_DIR"] = original_caller_developer_dir


def unsafe_tree_cases(cases: Path) -> None:
    root = cases / "unsafe-tree"
    root.mkdir()
    regular = root / "regular"
    regular.write_text("ok", encoding="utf-8")
    os.chmod(regular, 0o644)
    records, digest = unit.release_tree_records(root)
    check(len(records) == 1 and unit.SHA256_RE.fullmatch(digest) is not None, "ordinary release tree")

    symlink_root = cases / "symlink-tree"
    symlink_root.mkdir()
    os.symlink(regular, symlink_root / "link")
    expect_error(lambda: unit.release_tree_records(symlink_root), unit.INVALID_UNSAFE, "symlink tree")

    hardlink_root = cases / "hardlink-tree"
    hardlink_root.mkdir()
    original = hardlink_root / "one"
    original.write_text("same", encoding="utf-8")
    os.link(original, hardlink_root / "two")
    expect_error(lambda: unit.release_tree_records(hardlink_root), unit.INVALID_UNSAFE, "hardlink tree")

    fifo_root = cases / "fifo-tree"
    fifo_root.mkdir()
    os.mkfifo(fifo_root / "pipe", 0o600)
    expect_error(lambda: unit.release_tree_records(fifo_root), unit.INVALID_UNSAFE, "FIFO tree")


def nofollow_copy_cases(cases: Path) -> None:
    fixtures = cases / "copy-fixtures"
    fixtures.mkdir()

    safe_root = fixtures / "safe-root"
    (safe_root / "source/subdir").mkdir(parents=True)
    (safe_root / "source/subdir/file.txt").write_text("safe\n", encoding="utf-8")
    unit.copy_path_nofollow(
        safe_root,
        Path("source"),
        fixtures / "safe-copy",
        excluded_names=set(),
        label="safe fixture",
    )
    check((fixtures / "safe-copy/subdir/file.txt").read_text(encoding="utf-8") == "safe\n", "nofollow safe copy")

    symlink_root = fixtures / "source-symlink-root"
    (symlink_root / "source").mkdir(parents=True)
    os.symlink(safe_root / "source/subdir/file.txt", symlink_root / "source/link")
    expect_error(
        lambda: unit.copy_path_nofollow(
            symlink_root,
            Path("source"),
            fixtures / "source-symlink-copy",
            excluded_names=set(),
            label="source symlink fixture",
        ),
        unit.INVALID_UNSAFE,
        "source symlink copy",
    )

    parent_link_root = fixtures / "parent-link-root"
    parent_link_root.mkdir()
    os.symlink(safe_root / "source", parent_link_root / "linked")
    expect_error(
        lambda: unit.copy_path_nofollow(
            parent_link_root,
            Path("linked/subdir"),
            fixtures / "parent-link-copy",
            excluded_names=set(),
            label="parent symlink fixture",
        ),
        unit.INVALID_UNSAFE,
        "source parent symlink copy",
    )

    hardlink_root = fixtures / "hardlink-copy-root"
    (hardlink_root / "source").mkdir(parents=True)
    original = hardlink_root / "source/original"
    original.write_text("hardlink", encoding="utf-8")
    os.link(original, hardlink_root / "source/alias")
    expect_error(
        lambda: unit.copy_path_nofollow(
            hardlink_root,
            Path("source"),
            fixtures / "hardlink-copy",
            excluded_names=set(),
            label="hardlink fixture",
        ),
        unit.INVALID_UNSAFE,
        "source hardlink copy",
    )

    special_root = fixtures / "special-copy-root"
    (special_root / "source").mkdir(parents=True)
    os.mkfifo(special_root / "source/fifo", 0o600)
    expect_error(
        lambda: unit.copy_path_nofollow(
            special_root,
            Path("source"),
            fixtures / "special-copy",
            excluded_names=set(),
            label="special fixture",
        ),
        unit.INVALID_UNSAFE,
        "source special file copy",
    )

    dependency_root = fixtures / "dependency-root"
    dependency = dependency_root / "apps/desktop/.build/checkouts/GRDB.swift"
    dependency.mkdir(parents=True)
    (dependency / "Package.swift").write_text("// fixture\n", encoding="utf-8")
    os.symlink(dependency / "Package.swift", dependency / "unsafe-link")
    expect_error(
        lambda: unit.copy_grdb(dependency_root, fixtures / "dependency-copy"),
        unit.INVALID_UNSAFE,
        "dependency symlink copy",
    )

    resource_root = fixtures / "resource-root"
    resource_root.mkdir()
    (resource_root / "schema.json").write_text("{}\n", encoding="utf-8")
    os.symlink(resource_root / "schema.json", resource_root / "unsafe-link")
    expect_error(
        lambda: unit.copy_resource_tree(resource_root, fixtures / "resource-copy"),
        unit.INVALID_UNSAFE,
        "resource symlink copy",
    )


def _git(root: Path, *args: str) -> None:
    result = subprocess.run(
        [unit.GIT, *args],
        cwd=root,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if result.returncode != 0:
        raise CheckFailure(f"git fixture command failed: {args}: {result.stderr.decode(errors='replace')}")


def tracked_snapshot_cases(cases: Path) -> None:
    root = cases / "tracked-snapshot-repo"
    root.mkdir()
    _git(root, "init", "-q")
    tracked_files = {
        "apps/desktop/tracked.txt": "index bytes\n",
        "apps/browser-extension/tracked.txt": "extension\n",
        "contracts/schema.json": "{}\n",
        "config/app-release.json": "{}\n",
        "scripts/sync-contracts.sh": "#!/bin/sh\n",
        "scripts/native-host/stable_host.py": "# stable\n",
    }
    for relative, content in tracked_files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    (root / ".gitignore").write_text("*.ignored\n", encoding="utf-8")
    _git(root, "add", "--", *tracked_files, ".gitignore")
    (root / "apps/desktop/tracked.txt").write_text("live tracked modification\n", encoding="utf-8")
    for relative in (
        "apps/desktop/.cindy-write-test.txt",
        "apps/desktop/.dev-suite-analytics/event.json",
        "apps/desktop/.kb-cache/cache.bin",
        "apps/desktop/openwork-zh-translation/local.txt",
        "scripts/native-host/release_unit.py.backup.2026-08-06T09-12-20Z",
        "scripts/native-host/local.ignored",
    ):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("local only\n", encoding="utf-8")
    destination = cases / "tracked-snapshot-copy"
    unit.copy_source(root, destination)
    check(
        (destination / "apps/desktop/tracked.txt").read_text(encoding="utf-8") == "live tracked modification\n",
        "tracked live worktree modification copied",
    )
    check(not (destination / ".gitignore").exists(), "r4a source stayed within original six scopes")
    for relative in (
        "apps/desktop/.cindy-write-test.txt",
        "apps/desktop/.dev-suite-analytics",
        "apps/desktop/.kb-cache",
        "apps/desktop/openwork-zh-translation",
        "scripts/native-host/release_unit.py.backup.2026-08-06T09-12-20Z",
        "scripts/native-host/local.ignored",
    ):
        check(not (destination / relative).exists(), f"untracked or ignored source excluded: {relative}")

    object_id = b"1" * 40
    valid = b"100644 " + object_id + b" 0\tapps/desktop/file\0"
    check(unit.parse_git_tracked_entries(valid) == [(0o100644, "apps/desktop/file")], "strict Git index parser ordinary entry")
    for payload, label in (
        (b"120000 " + object_id + b" 0\tlink\0", "tracked symlink mode"),
        (b"160000 " + object_id + b" 0\tsubmodule\0", "tracked submodule mode"),
        (b"100644 " + object_id + b" 1\tconflict\0", "non-stage-0 entry"),
        (valid + valid, "duplicate tracked path"),
        (b"100644 " + object_id + b" 0\t../escape\0", "unsafe parent path"),
        (b"100644 " + object_id + b" 0\t/absolute\0", "absolute path"),
        (b"100644 " + object_id + b" 0\t.\0", "dot path"),
        (b"100644 " + object_id + b" 0\tbad-\xff\0", "non-UTF-8 path"),
        (b"100644 " + (b"0" * 40) + b" 0\tintent-to-add\0", "null object entry"),
    ):
        expect_error(lambda payload=payload: unit.parse_git_tracked_entries(payload), unit.INVALID_UNSAFE, label)
    expect_error(
        lambda: unit.parse_git_tracked_entries(b"100644 " + object_id + b" 0\t\0"),
        unit.INTERNAL_ERROR,
        "empty path",
    )

    hardlink_root = cases / "tracked-hardlink-repo"
    hardlink_root.mkdir()
    _git(hardlink_root, "init", "-q")
    hardlink_file = hardlink_root / "tracked"
    hardlink_file.write_text("x", encoding="utf-8")
    _git(hardlink_root, "add", "tracked")
    os.link(hardlink_file, hardlink_root / "untracked-alias")
    hardlink_entries = unit.git_tracked_entries(hardlink_root)
    expect_error(
        lambda: unit.tracked_worktree_records(hardlink_root, hardlink_entries),
        unit.INVALID_UNSAFE,
        "tracked worktree hardlink",
    )

    ancestor_root = cases / "tracked-ancestor-symlink-repo"
    ancestor_root.mkdir()
    _git(ancestor_root, "init", "-q")
    (ancestor_root / "directory").mkdir()
    (ancestor_root / "directory/file").write_text("x", encoding="utf-8")
    _git(ancestor_root, "add", "directory/file")
    (ancestor_root / "directory").rename(ancestor_root / "directory-real")
    (ancestor_root / "directory").symlink_to("directory-real")
    expect_error(
        lambda: unit.tracked_worktree_records(ancestor_root, unit.git_tracked_entries(ancestor_root)),
        unit.INVALID_UNSAFE,
        "tracked source symlink ancestor",
    )

    concurrent_root = cases / "tracked-concurrent-repo"
    concurrent_root.mkdir()
    _git(concurrent_root, "init", "-q")
    concurrent_file = concurrent_root / "large.bin"
    concurrent_file.write_bytes(b"a" * (2 * 1024 * 1024))
    _git(concurrent_root, "add", "large.bin")
    fired = False

    def mutate(_relative: Path, copied: int) -> None:
        nonlocal fired
        if not fired and copied >= 1024 * 1024:
            fired = True
            with concurrent_file.open("ab") as handle:
                handle.write(b"b")

    concurrent_destination = cases / "tracked-concurrent-copy"
    concurrent_destination.mkdir()
    expect_error(
        lambda: unit.tracked_worktree_records(
            concurrent_root,
            unit.git_tracked_entries(concurrent_root),
            destination=concurrent_destination,
            copy_hook=mutate,
        ),
        unit.CLEANUP_REQUIRED,
        "tracked source concurrent mutation",
    )

    destination_race_root = cases / "tracked-destination-race-repo"
    destination_race_root.mkdir()
    _git(destination_race_root, "init", "-q")
    destination_race_file = destination_race_root / "nested/file.bin"
    destination_race_file.parent.mkdir()
    destination_race_file.write_bytes(b"tracked destination race\n")
    _git(destination_race_root, "add", "nested/file.bin")
    destination_race_copy = cases / "tracked-destination-race-copy"
    destination_race_copy.mkdir()
    destination_race_outside = cases / "tracked-destination-race-outside"
    destination_race_outside.mkdir()
    original_open = unit.os.open
    destination_swapped = False

    def replace_destination_ancestor(
        path: str | bytes | os.PathLike[str],
        flags: int,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> int:
        nonlocal destination_swapped
        if (
            not destination_swapped
            and os.fspath(path) == "file.bin"
            and flags & os.O_CREAT
            and dir_fd is not None
        ):
            destination_swapped = True
            ancestor = destination_race_copy / "nested"
            ancestor.rename(destination_race_copy / "nested-opened")
            ancestor.symlink_to(destination_race_outside, target_is_directory=True)
        return original_open(path, flags, mode, dir_fd=dir_fd)

    unit.os.open = replace_destination_ancestor
    try:
        expect_error(
            lambda: unit.tracked_worktree_records(
                destination_race_root,
                unit.git_tracked_entries(destination_race_root),
                destination=destination_race_copy,
            ),
            unit.CLEANUP_REQUIRED,
            "tracked destination ancestor concurrent replacement",
        )
    finally:
        unit.os.open = original_open
    check(destination_swapped, "tracked destination race hook fired")
    check(
        not (destination_race_outside / "file.bin").exists(),
        "tracked destination ancestor replacement never writes outside snapshot root",
    )


def clone_staging(audit: Path, cases: Path, name: str) -> Path:
    target = cases / name
    unit.copy_path_nofollow(
        audit,
        Path("staging"),
        target,
        excluded_names=set(),
        label=f"candidate staging clone {name}",
    )
    return target


def staging_tamper_cases(audit: Path, cases: Path) -> None:
    source = audit / "source"
    config = unit.load_app_config(ROOT)
    pristine = unit.validate_staging(audit / "staging", source, config)
    check(pristine["releaseUnit"]["productStatus"] == "BLOCKED", "pristine staging strict verify")

    extra = clone_staging(audit, cases, "extra")
    (extra / "unexpected").write_text("x", encoding="utf-8")
    expect_error(lambda: unit.validate_staging(extra, source, config), unit.INVALID_UNSAFE, "staging extra entry")

    plist_case = clone_staging(audit, cases, "plist-drift")
    plist_path = plist_case / unit.APP_BUNDLE / "Contents/Info.plist"
    plist_value = plistlib.loads(plist_path.read_bytes())
    plist_value["CFBundleVersion"] = "999"
    plist_path.write_bytes(plistlib.dumps(plist_value, fmt=plistlib.FMT_XML, sort_keys=True))
    expect_error(lambda: unit.validate_staging(plist_case, source, config), unit.INVALID_UNSAFE, "plist build drift")

    package_case = clone_staging(audit, cases, "package-drift")
    metadata = package_case / unit.APP_BUNDLE / "Contents/Resources/NativeHost/LinkDigestNativeHost-0.2.0-macos-arm64/package.json"
    value = json.loads(metadata.read_text(encoding="utf-8"))
    value["minimumMacOS"] = "14.0"
    metadata.write_bytes(unit.canonical_bytes(value))
    expect_error(lambda: unit.validate_staging(package_case, source, config), unit.INVALID_UNSAFE, "Host package drift")

    icon_case = clone_staging(audit, cases, "icon-drift")
    icon = icon_case / unit.APP_BUNDLE / "Contents/Resources/AppIcon.icns"
    with icon.open("ab") as handle:
        handle.write(b"drift")
    expect_error(lambda: unit.validate_staging(icon_case, source, config), unit.INVALID_UNSAFE, "App icon hash drift")

    extension_case = clone_staging(audit, cases, "browser-extension-drift")
    extension_background = extension_case / unit.APP_BUNDLE / "Contents/Resources/BrowserExtension/background.js"
    with extension_background.open("ab") as handle:
        handle.write(b"drift")
    expect_error(
        lambda: unit.validate_staging(extension_case, source, config),
        unit.INVALID_UNSAFE,
        "embedded browser extension drift",
    )

    mixed = clone_staging(audit, cases, "mixed-unit")
    unit_path = mixed / "release-unit.json"
    value = json.loads(unit_path.read_text(encoding="utf-8"))
    value["app"]["executableHash"] = "0" * 64
    unit_path.write_bytes(unit.canonical_bytes(value))
    expect_error(lambda: unit.validate_staging(mixed, source, config), unit.INVALID_UNSAFE, "mixed release unit")

    original_arch = unit.macho_architectures
    original_minimum = unit.macho_minimum_macos
    try:
        # App 只剩单一切片（缺 arm64），Host 仍是完整 universal：必须被拒。
        # universal 之后这条正好覆盖「漏了一个架构就发出去」这种真实事故。
        unit.macho_architectures = (
            lambda path: ["x86_64"] if path.name == "LinkDigestApp"
            else list(unit.stable_host.SUPPORTED_ARCHITECTURES)
        )
        expect_error(
            lambda: unit.verify_app(audit / "staging" / unit.APP_BUNDLE, None, source, config),
            unit.INVALID_UNSAFE,
            "App architecture drift",
        )
        unit.macho_architectures = original_arch
        unit.macho_minimum_macos = lambda path: "14" if path.name == "LinkDigestApp" else "15"
        expect_error(
            lambda: unit.verify_app(audit / "staging" / unit.APP_BUNDLE, None, source, config),
            unit.INVALID_UNSAFE,
            "App minimum macOS drift",
        )
    finally:
        unit.macho_architectures = original_arch
        unit.macho_minimum_macos = original_minimum


def fake_dmg_cases(cases: Path) -> None:
    mount = cases / "fake-mount"
    mount.mkdir()
    one = {"system-entities": [{"dev-entry": "/dev/disk99s1", "mount-point": str(mount)}]}
    check(unit.parse_attach_plist(plistlib.dumps(one), mount) == "/dev/disk99s1", "unique attach plist")
    ambiguous = {
        "system-entities": [
            {"dev-entry": "/dev/disk99s1", "mount-point": str(mount)},
            {"dev-entry": "/dev/disk100s1", "mount-point": str(mount)},
        ]
    }
    expect_error(lambda: unit.parse_attach_plist(plistlib.dumps(ambiguous), mount), unit.CLEANUP_REQUIRED, "ambiguous attach plist")
    expect_error(lambda: unit.parse_attach_plist(b"not a plist", mount), unit.CLEANUP_REQUIRED, "invalid attach plist")

    dmg = cases / "fake.dmg"
    dev = "/dev/disk99"

    def info_payload(devices: list[str]) -> bytes:
        entities = [{"dev-entry": item, "mount-point": str(mount)} for item in devices]
        return plistlib.dumps({"images": [{"image-path": str(dmg), "system-entities": entities}] if devices else []})

    def run_sequence(
        attach: subprocess.CompletedProcess[bytes],
        *,
        infos: list[bytes],
        ordinary_detach: int = 0,
        force_detach: int = 0,
        expected_code: int | None = None,
    ) -> list[list[str]]:
        original_run = unit.run_command
        calls: list[list[str]] = []
        info_queue = list(infos)

        def runner(argv: list[str], **_kwargs: Any) -> subprocess.CompletedProcess[bytes]:
            calls.append(argv)
            if argv[1:3] == ["info", "-plist"]:
                payload = info_queue.pop(0) if info_queue else info_payload([])
                return subprocess.CompletedProcess(argv, 0, payload, b"")
            if argv[1:2] == ["verify"]:
                return subprocess.CompletedProcess(argv, 0, b"", b"")
            if argv[1:3] == ["detach", "-force"]:
                return subprocess.CompletedProcess(argv, force_detach, b"", b"force-fail" if force_detach else b"")
            if argv[1:2] == ["detach"]:
                return subprocess.CompletedProcess(argv, ordinary_detach, b"", b"detach-fail" if ordinary_detach else b"")
            raise CheckFailure(f"unexpected fake hdiutil command: {argv}")

        try:
            unit.run_command = runner
            action = lambda: unit.guarded_attach_operation(attach, dmg, mount, lambda actual: actual)
            if expected_code is None:
                check(action() == dev, "guarded attach operation succeeded")
            else:
                expect_error(action, expected_code, f"guarded attach exit {expected_code}")
            return calls
        finally:
            unit.run_command = original_run

    valid_attach = subprocess.CompletedProcess(
        [unit.HDITUTIL, "attach"],
        0,
        plistlib.dumps({"system-entities": [{"dev-entry": dev, "mount-point": str(mount)}]}),
        b"",
    )
    calls = run_sequence(valid_attach, infos=[info_payload([dev]), info_payload([])])
    check(any(command[1:2] == ["detach"] for command in calls), "successful attach exact detach")

    mismatched_attach = subprocess.CompletedProcess(
        [unit.HDITUTIL, "attach"],
        0,
        plistlib.dumps({"system-entities": [{"dev-entry": "/dev/disk100", "mount-point": str(mount)}]}),
        b"",
    )
    calls = run_sequence(
        mismatched_attach,
        infos=[info_payload([dev]), info_payload([])],
        expected_code=unit.CLEANUP_REQUIRED,
    )
    check(any(command[1:2] == ["detach"] for command in calls), "mismatched success plist detached exact current device")

    invalid_attach = subprocess.CompletedProcess([unit.HDITUTIL, "attach"], 0, b"invalid", b"")
    calls = run_sequence(invalid_attach, infos=[info_payload([dev]), info_payload([])], expected_code=unit.CLEANUP_REQUIRED)
    check(any(command[1:2] == ["detach"] for command in calls), "invalid plist recovered and detached")

    ambiguous_attach = subprocess.CompletedProcess([unit.HDITUTIL, "attach"], 0, plistlib.dumps(ambiguous), b"")
    calls = run_sequence(ambiguous_attach, infos=[info_payload([dev]), info_payload([])], expected_code=unit.CLEANUP_REQUIRED)
    check(any(command[1:2] == ["detach"] for command in calls), "ambiguous plist recovered and detached")

    partial_attach = subprocess.CompletedProcess([unit.HDITUTIL, "attach"], 1, b"", b"partial")
    calls = run_sequence(partial_attach, infos=[info_payload([dev]), info_payload([])], expected_code=unit.ENVIRONMENT_BLOCKED)
    check(any(command[1:2] == ["detach"] for command in calls), "partial attach recovered and detached")

    calls = run_sequence(partial_attach, infos=[info_payload([])], expected_code=unit.CLEANUP_REQUIRED)
    check(not any(command[1:2] == ["detach"] for command in calls), "unbound partial attach refuses guessed detach")

    calls = run_sequence(
        valid_attach,
        infos=[info_payload([dev]), info_payload([dev]), info_payload([])],
        ordinary_detach=1,
        force_detach=0,
    )
    check(any(command[1:3] == ["detach", "-force"] for command in calls), "force follows exact reconfirmation")

    calls = run_sequence(
        valid_attach,
        infos=[info_payload([dev]), info_payload([dev]), info_payload([dev])],
        ordinary_detach=1,
        force_detach=0,
        expected_code=unit.CLEANUP_REQUIRED,
    )
    check(any(command[1:3] == ["detach", "-force"] for command in calls), "residual force path attempted once")


def target_cases(cases: Path) -> None:
    absent = unit.probe_one("fixture", cases / "absent", "manifest")
    check(absent["state"] == "absent", "target absent state")

    manifest_path = cases / "manifest.json"
    manifest = {
        "allowed_origins": ["chrome-extension://" + "a" * 32 + "/"],
        "description": "LinkDigest Native Messaging Host",
        "name": "com.syc.linkdigest.v01",
        "path": "/private/tmp/LinkDigestNativeHost",
        "type": "stdio",
    }
    canonical_file(manifest_path, manifest)
    check(unit.probe_one("fixture", manifest_path, "manifest")["state"] == "owned", "target manifest owned")

    parent_real = cases / "target-parent-real"
    parent_real.mkdir()
    canonical_file(parent_real / "manifest.json", manifest)
    parent_link = cases / "target-parent-link"
    os.symlink(parent_real, parent_link)
    linked = unit.probe_one("fixture", parent_link / "manifest.json", "manifest")
    check(
        linked["state"] == "unknown" and linked["reason"] in {"symlink-component", "unsafe-parent-component"},
        "target parent symlink rejected",
    )

    swap_path = cases / "swap-manifest.json"
    canonical_file(swap_path, manifest)
    swapped_old = cases / "swap-manifest.old"

    def swap_leaf(path: Path) -> None:
        path.rename(swapped_old)
        canonical_file(path, manifest)

    swapped = unit.probe_one("fixture", swap_path, "manifest", after_open=swap_leaf)
    check(swapped["state"] == "unknown" and swapped["reason"] == "leaf-changed-during-probe", "target leaf swap rejected")

    oversized_path = cases / "oversized-manifest.json"
    oversized_path.write_bytes(b"x" * (256 * 1024 + 1))
    os.chmod(oversized_path, 0o600)
    oversized = unit.probe_one("fixture", oversized_path, "manifest")
    check(oversized["state"] == "malformed" and oversized["reason"] == "size-limit" and oversized["contentHash"] is None, "target oversized bounded read")

    hardlink_path = cases / "hardlinked-manifest.json"
    canonical_file(hardlink_path, manifest)
    os.link(hardlink_path, cases / "hardlinked-manifest.alias")
    hardlinked = unit.probe_one("fixture", hardlink_path, "manifest")
    check(hardlinked["state"] == "unknown" and hardlinked["reason"] == "not-single-link-regular-file", "target hardlink rejected")

    fifo_path = cases / "target-fifo"
    os.mkfifo(fifo_path, 0o600)
    fifo = unit.probe_one("fixture", fifo_path, "manifest")
    check(fifo["state"] == "unknown", "target FIFO rejected without blocking")

    manifest["extra"] = True
    canonical_file(manifest_path, manifest)
    check(unit.probe_one("fixture", manifest_path, "manifest")["state"] == "malformed", "target manifest drift")

    receipt1 = {
        "formatVersion": 1,
        "hostName": "com.syc.linkdigest.v01",
        "installedVersion": "0.2.0-macos-arm64",
        "packageDigest": "1" * 64,
        "versionDirectory": "/private/tmp/version",
        "ownedManifests": [{"path": "/private/tmp/manifest", "sha256": "2" * 64}],
    }
    receipt1_path = cases / "receipt-v1.json"
    canonical_file(receipt1_path, receipt1)
    check(unit.probe_one("fixture", receipt1_path, "receipt-v1")["state"] == "owned", "target receipt v1")

    tree = {"directories": [], "files": [], "packageDigest": "3" * 64, "path": "/private/tmp/version", "version": "0.2.0"}
    receipt2 = {
        "current": tree,
        "formatVersion": 2,
        "hostName": "com.syc.linkdigest.v01",
        "lineage": [],
        "ownedManifests": [{"hash": "4" * 64, "mode": "0600", "path": "/private/tmp/manifest", "role": "brave-default"}],
    }
    receipt2_path = cases / "receipt-v2.json"
    canonical_file(receipt2_path, receipt2)
    check(unit.probe_one("fixture", receipt2_path, "receipt-v2")["state"] == "owned", "target receipt v2")

    old_home = os.environ.get("HOME")
    old_tmp = os.environ.get("TMPDIR")
    baseline = [(token, str(path), kind) for token, path, kind in unit.fixed_target_paths()]
    try:
        os.environ["HOME"] = str(cases)
        os.environ["TMPDIR"] = str(ROOT)
        hostile = [(token, str(path), kind) for token, path, kind in unit.fixed_target_paths()]
    finally:
        if old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = old_home
        if old_tmp is None:
            os.environ.pop("TMPDIR", None)
        else:
            os.environ["TMPDIR"] = old_tmp
    check(hostile == baseline, "target probe ignores hostile HOME/TMPDIR")


def source_policy_checks() -> None:
    source = (ROOT / "scripts/native-host/release_unit.py").read_text(encoding="utf-8")
    tree = ast.parse(source)
    shell_true = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.keyword) and node.arg == "shell" and isinstance(node.value, ast.Constant) and node.value.value is True
    ]
    check(not shell_true, "no shell=True")
    check('"-s"' not in source and "' -s '" not in source, "no codesign signing argv")
    check("notarytool" not in source and "security find-identity" not in source and "spctl" not in source, "no forbidden release tools")
    probe_source = source[source.index("def fixed_target_paths") : source.index("def build_release_unit")]
    check("listdir(" not in probe_source and ".glob(" not in probe_source, "real target probe has no listdir/glob")
    checker = (ROOT / "scripts/native-host/release_unit_check.py").read_text(encoding="utf-8")
    swift_source = checker[checker.index("def swift_tests") : checker.index("def config_cases")]
    check("ProviderStoreTests" not in swift_source and '"--skip"' not in swift_source, "r4a gate has no full Swift suite")
    check('"--filter", "ContractTests"' not in swift_source, "r4a gate rejects fuzzy ContractTests filter")
    check(
        '"--filter", "LinkDigestCoreTests.ContractTests"' in swift_source
        and "Executed 11 tests, with 0 failures" in swift_source
        and "return 11" in swift_source,
        "r4a gate pins exact ContractTests suite and count",
    )


def run_real_target_probe() -> dict[str, Any]:
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts/native-host/release_unit.py"), "probe-targets"],
        cwd=ROOT,
        env={
            "HOME": "/private/tmp/hostile-home-ignored",
            "TMPDIR": str(ROOT),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
            "PYTHONDONTWRITEBYTECODE": "1",
        },
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    check(result.returncode == unit.BLOCKED, "real target probe exits 10")
    try:
        value = json.loads(result.stdout.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CheckFailure(f"real target probe output is invalid JSON: {error}") from error
    check(isinstance(value, dict) and unit.canonical_bytes(value) == result.stdout, "real target probe canonical JSON")
    check(value.get("unchanged") is True and value.get("status") == "BLOCKED", "real target probe unchanged and blocked")
    targets = value.get("targets")
    check(isinstance(targets, list) and all(isinstance(item, dict) for item in targets), "real target probe target records")
    check(
        tuple(item.get("token") for item in targets) == unit.TARGET_PROBE_TOKENS,
        "real target probe exact independent token contract",
    )
    return value


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--existing-audit", required=True)
    parser.add_argument("--review-root", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    audit = Path(args.existing_audit)
    review = Path(args.review_root)
    print("release-unit-check: candidate audit and review root are intentionally retained")
    print(f"AUDIT_ROOT={audit}")
    print(f"REVIEW_ROOT={review}")
    try:
        audit = unit.validate_existing_audit_root(str(audit))
        review = validate_new_review_root(str(review))
        audit_inventory_before = unit.inventory_tree(audit, include_metadata=True)
        review.mkdir(mode=0o700)
        report = unit.load_json(audit / "r4a-engineering-report.json", "r4a engineering report")
        check(unit.canonical_bytes(report) == (audit / "r4a-engineering-report.json").read_bytes(), "engineering report canonical JSON")
        check(report["engineeringStatus"] == "candidate", "engineering status candidate")
        check(report["productStatus"] == "BLOCKED", "product status blocked")
        check(report["separateAuthorizationRequired"] is True, "separate authorization required")
        check(report["workspaceInventoryUnchanged"] is True, "workspace inventory unchanged")
        check(report["residualMounts"] is False, "no residual mount")
        check(Path(report["dmg"]).is_file(), "real DMG exists")
        source = audit / "source"
        app_config = unit.load_app_config(source)
        staging = unit.validate_staging(audit / "staging", source, app_config)
        actual_dmg_hash = unit.sha256_file(Path(report["dmg"]))
        actual_unit_hash = unit.sha256_file(audit / "staging/release-unit.json")
        actual_app_tree = staging["appResult"]["appTreeDigest"]
        check(actual_dmg_hash == report["dmgHash"], "candidate DMG hash binding")
        check(actual_unit_hash == report["releaseUnitHash"], "candidate release-unit hash binding")
        check(actual_app_tree == staging["releaseUnit"]["app"]["treeDigest"], "candidate App tree binding")
        unit.command_ok([unit.HDITUTIL, "verify", str(Path(report["dmg"]))], allowed={unit.HDITUTIL})
        check(True, "candidate DMG hdiutil verify")

        cases = review / "cases"
        cases.mkdir(mode=0o700)
        config_cases(cases)
        xcode_selection_cases(cases)
        universal_build_argument_cases(cases)
        swift_test_xcode_env_cases(cases)
        unsafe_tree_cases(cases)
        nofollow_copy_cases(cases)
        tracked_snapshot_cases(cases)
        staging_tamper_cases(audit, cases)
        fake_dmg_cases(cases)
        target_cases(cases)
        source_policy_checks()
        real_probe = run_real_target_probe()
        focused_tests = swift_tests(audit, review)

        audit_inventory_after = unit.inventory_tree(audit, include_metadata=True)
        check(audit_inventory_after == audit_inventory_before, "existing candidate audit remained byte/metadata read-only")
        source_inventory = unit.inventory_tree(source, include_metadata=False)
        gate_result = {
            "candidate": {
                "appTreeDigest": actual_app_tree,
                "auditInventoryHash": audit_inventory_after,
                "dmgHash": actual_dmg_hash,
                "releaseUnitHash": actual_unit_hash,
                "sourceInventoryHash": source_inventory,
            },
            "commands": [
                "hdiutil verify candidate DMG",
                "release_unit.py probe-targets",
                "swift test --filter LinkDigestCoreTests.ContractTests",
                "release_unit_check.py focused-negative",
            ],
            "engineeringStatus": "remediation-candidate",
            "exitStatus": 0,
            "formatVersion": 1,
            "networkPolicy": "no-tcp-listener-no-external-network",
            "productStatus": "BLOCKED",
            "review": {
                "assertions": TESTS + 1,
                "focusedSwiftTests": focused_tests,
                "targetProbeExpectedExit": unit.BLOCKED,
            },
            "targetProbe": real_probe,
            "toolHashes": {
                "releaseUnitCheck": unit.sha256_file(ROOT / "scripts/native-host/release_unit_check.py"),
                "releaseUnitCore": unit.sha256_file(ROOT / "scripts/native-host/release_unit.py"),
            },
        }
        result_path = review / "gate-result.json"
        result_path.write_bytes(unit.canonical_bytes(gate_result))
        os.chmod(result_path, 0o600)
        check(unit.canonical_bytes(gate_result) == result_path.read_bytes(), "canonical gate-result binding")

        print(f"release-unit-check: candidate gate complete ({TESTS} assertions)")
        print(f"DMG={report['dmg']}")
        print(f"GATE_RESULT={result_path}")
        return 0
    except (CheckFailure, unit.ReleaseUnitError) as error:
        print(f"release-unit-check: FAIL: {error}", file=sys.stderr)
        print(f"release-unit-check: audit/review retained at {audit} / {review}", file=sys.stderr)
        return error.code if isinstance(error, unit.ReleaseUnitError) else 1
    except BaseException as error:
        print(f"release-unit-check: INTERNAL: {error}", file=sys.stderr)
        print(f"release-unit-check: audit/review retained at {audit} / {review}", file=sys.stderr)
        return unit.INTERNAL_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
