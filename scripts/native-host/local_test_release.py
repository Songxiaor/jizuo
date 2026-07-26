#!/usr/bin/env python3
"""Create the LinkDigest r4b local-test ad-hoc DMG candidate.

This is deliberately a local-test pipeline, not a public release pipeline.  It
freezes the live dirty worktree without Git, builds only from deterministic
source archives in an isolated environment, signs inside-out with ad-hoc
identities, verifies a readonly DMG mount, and emits a self-contained handoff.
"""

from __future__ import annotations

import argparse
import errno
import gzip
import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Sequence

sys.dont_write_bytecode = True

SCRIPT_ROOT = Path(__file__).resolve().parents[1]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

import extension_identity_artifact as extension_artifact
import release_unit as r4a
import stable_host


SUCCESS = 0
INVALID_UNSAFE = 2
CLEANUP_REQUIRED = 8
BLOCKED = 10
ENVIRONMENT_BLOCKED = 20
INTERNAL_ERROR = 70

AUDIT_PREFIX = "linkdigest-r4b-local-test."
REVIEW_PREFIX = "linkdigest-r4b-review."
CONFIG_RELATIVE = Path("config/local-test-release.json")
RESOURCE_BUNDLE = "LinkDigest_LinkDigestCore.bundle"
APP_ICON_FILE = "AppIcon.icns"
PLATFORM_ICONS_DIRECTORY = "PlatformIcons"
PLATFORM_ICON_FILES = ("bilibili.svg", "douban.svg", "douyin.svg", "github.svg", "juejin.svg", "medium.svg", "reddit.svg", "toutiao.svg", "wechat.svg", "weibo.svg", "x.com.svg", "xiaohongshu.svg", "youtube.svg", "zhihu.svg")
PROVIDER_ICONS_DIRECTORY = "ProviderIcons"
PROVIDER_ICON_FILES = ("bailian.svg", "deepinfra.svg", "deepseek.svg", "groq.svg", "ollama.svg", "openai.svg", "openrouter.svg", "siliconflow.svg", "stepfun.svg", "zhipu.svg")
HOST_PACKAGE_NAME = "LinkDigestNativeHost-0.2.0-macos-arm64"
LOCAL_TEST_UNIT = "local-test-unit.json"
SOURCE_MANIFEST = "SOURCE_MANIFEST.json"
TOOL_HASHES = "TOOL_HASHES.json"
APP_TREE = "APP_TREE.json"
VERIFICATION_REPORT = "VERIFICATION_REPORT.json"

SWIFT = "/usr/bin/swift"
CODESIGN = "/usr/bin/codesign"
HDITUTIL = "/usr/bin/hdiutil"
LIPO = "/usr/bin/lipo"
OTOOL = "/usr/bin/otool"
SW_VERS = "/usr/bin/sw_vers"

O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SECRET_NAME_RE = re.compile(
    r"(?:^|[._-])(api[_-]?key|auth[_-]?token|cookie|credential|password|private[_-]?key|secret)(?:$|[._-])",
    re.IGNORECASE,
)
SECRET_CONTENT_PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"(?<![A-Za-z0-9])sk-(?:proj-)?[A-Za-z0-9_-]{32,}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
)

CONFIG_KEYS = {
    "formatVersion",
    "acceptanceGuideSource",
    "version",
    "distributionClass",
    "appBundle",
    "appIdentifier",
    "hostIdentifier",
    "minimumMacOS",
    "architectures",
    "browserExtension",
    "dmgName",
    "handoffDirectory",
    "sourceArchive",
    "sourceTreeName",
    "grdbArchive",
    "grdbVersion",
    "unitID",
    "sourceTopLevelAllowlist",
    "excludedTopLevel",
    "excludedBasenames",
    "excludedSuffixes",
    "r4aFrozenHashes",
    "secretFixtureHashAllowlist",
}

REQUIRED_R4A_FROZEN_PATHS = {
    "apps/desktop/Assets/AppIcon.icns",
    "config/app-release.json",
    "scripts/native-host/check-release-unit.sh",
    "scripts/native-host/package-app-dmg.sh",
    "scripts/native-host/release_unit.py",
    "scripts/native-host/release_unit_check.py",
}


class LocalTestError(RuntimeError):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code


def reject(message: str, code: int = INVALID_UNSAFE) -> "None":
    raise LocalTestError(code, message)


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_canonical(path: Path, value: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_bytes(value))
    os.chmod(path, mode)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_fd(fd: int) -> str:
    digest = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while chunk := os.read(fd, 1024 * 1024):
        digest.update(chunk)
    os.lseek(fd, 0, os.SEEK_SET)
    return digest.hexdigest()


def byte_sorted(values: Iterable[str]) -> list[str]:
    return sorted(values, key=os.fsencode)


def mode_text(mode: int) -> str:
    return f"0{stat.S_IMODE(mode):03o}"


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        reject(f"{label} is invalid JSON: {error}")
    if not isinstance(value, dict):
        reject(f"{label} must be one JSON object")
    return value


def load_config(root: Path | None = None) -> dict[str, Any]:
    root = root or repository_root()
    value = load_json(root / CONFIG_RELATIVE, "local-test config")
    if set(value) != CONFIG_KEYS:
        reject("local-test config keys drifted")
    exact: dict[str, Any] = {
        "acceptanceGuideSource": "docs/ACCEPTANCE_GUIDE.md",
        "formatVersion": 1,
        "version": "0.2.0",
        "distributionClass": "local-test-ad-hoc",
        "appBundle": "LinkDigest.app",
        "appIdentifier": "com.syc.linkdigest",
        "hostIdentifier": "com.syc.linkdigest.native-host",
        "minimumMacOS": "15.0",
        "architectures": ["arm64"],
        "dmgName": "LinkDigest-0.2.0-local-test-macos-arm64.dmg",
        "handoffDirectory": "LinkDigest-0.2.0-local-test",
        "sourceArchive": "LinkDigest-0.2.0-live-worktree-source.tar.gz",
        "sourceTreeName": "LinkDigest-0.2.0-live-worktree-source",
        "grdbArchive": "GRDB.swift-7.11.1-source.tar.gz",
        "grdbVersion": "7.11.1",
        "unitID": "com.syc.linkdigest.local-test-unit.v1",
    }
    for key, expected in exact.items():
        if type(value[key]) is not type(expected) or value[key] != expected:
            reject(f"local-test config {key} must be {expected!r}")
    acceptance_guide = value["acceptanceGuideSource"]
    if not isinstance(acceptance_guide, str) or acceptance_guide != "docs/ACCEPTANCE_GUIDE.md":
        reject("local-test config acceptanceGuideSource must be the exact guide path")
    browser_extension = value["browserExtension"]
    expected_browser_extension = {
        "artifactSource": "apps/browser-extension/identity-artifact/LinkDigest-extension-0.2.0-chromium.zip",
        "extensionID": "fbpjhlcpfheecigibjghhodhhkgjdgma",
        "handoffDirectory": "extension",
        "identityConfig": "config/extension-identity.json",
        "manifestTemplateDirectory": "apps/browser-extension/identity-artifact/native-host-manifests",
        "version": "0.2.0",
    }
    if browser_extension != expected_browser_extension:
        reject("local-test config browserExtension must match the frozen technical identity")
    for key in ("sourceTopLevelAllowlist", "excludedTopLevel", "excludedBasenames", "excludedSuffixes"):
        items = value[key]
        if not isinstance(items, list) or not items or not all(isinstance(item, str) and item for item in items):
            reject(f"local-test config {key} must be a non-empty string list")
        if items != byte_sorted(set(items)):
            reject(f"local-test config {key} must be unique and byte-sorted")
    hashes = value["r4aFrozenHashes"]
    if not isinstance(hashes, dict) or not hashes or not all(
        isinstance(path, str) and isinstance(digest, str) and SHA256_RE.fullmatch(digest)
        for path, digest in hashes.items()
    ):
        reject("r4aFrozenHashes is invalid")
    if set(hashes) != REQUIRED_R4A_FROZEN_PATHS:
        reject("r4aFrozenHashes keys do not match the frozen exact set")
    fixture_hashes = value["secretFixtureHashAllowlist"]
    if not isinstance(fixture_hashes, dict) or not fixture_hashes or not all(
        isinstance(path, str)
        and not path.startswith("/")
        and isinstance(digest, str)
        and SHA256_RE.fullmatch(digest)
        for path, digest in fixture_hashes.items()
    ):
        reject("secretFixtureHashAllowlist is invalid")
    return value


def validate_lexical_absolute(value: str, label: str) -> Path:
    try:
        return r4a.validate_lexical_absolute(value, label)
    except r4a.ReleaseUnitError as error:
        reject(str(error), error.code)


def assert_real_components(path: Path, label: str, *, final_may_be_missing: bool = False) -> None:
    try:
        r4a.assert_real_components(path, label, final_may_be_missing=final_may_be_missing)
    except r4a.ReleaseUnitError as error:
        reject(str(error), error.code)


def validate_new_named_root(value: str, prefix: str, label: str) -> Path:
    path = validate_lexical_absolute(value, label)
    if path.parent != Path("/private/tmp") or not path.name.startswith(prefix) or len(path.name) <= len(prefix):
        reject(f"{label} must be a new /private/tmp direct child named {prefix}*")
    assert_real_components(path.parent, f"{label} parent")
    if path.parent.resolve(strict=True) != path.parent or os.path.lexists(path):
        reject(f"{label} must be canonical and absent")
    return path


def validate_new_audit_root(value: str) -> Path:
    return validate_new_named_root(value, AUDIT_PREFIX, "--audit-root")


def validate_existing_audit_root(value: str) -> Path:
    path = validate_lexical_absolute(value, "--existing-audit")
    if path.parent != Path("/private/tmp") or not path.name.startswith(AUDIT_PREFIX):
        reject("--existing-audit is outside the r4b namespace")
    assert_real_components(path, "existing audit")
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        reject("existing audit must be a current-user-owned 0700 directory")
    return path


def run_command(
    argv: Sequence[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_bytes: bytes | None = None,
    timeout: int = 1800,
) -> subprocess.CompletedProcess[bytes]:
    if not argv or not os.path.isabs(argv[0]):
        reject("subprocess argv[0] must be absolute", INTERNAL_ERROR)
    try:
        return subprocess.run(
            list(argv),
            cwd=cwd,
            env=env,
            input=input_bytes,
            stdin=subprocess.DEVNULL if input_bytes is None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        reject(f"environment could not run {argv[0]}: {error}", ENVIRONMENT_BLOCKED)


def command_ok(argv: Sequence[str], **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
    result = run_command(argv, **kwargs)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).decode("utf-8", errors="replace")[-2000:]
        reject(f"command failed ({result.returncode}): {argv[0]}: {detail}", ENVIRONMENT_BLOCKED)
    return result


def verify_r4a_frozen(root: Path, config: dict[str, Any]) -> dict[str, str]:
    actual: dict[str, str] = {}
    for relative, expected in sorted(config["r4aFrozenHashes"].items(), key=lambda item: os.fsencode(item[0])):
        path = root / relative
        if not path.is_file() or path.is_symlink():
            reject(f"frozen r4a file missing or unsafe: {relative}")
        digest = sha256_file(path)
        if digest != expected:
            reject(f"frozen r4a compatibility hash drifted: {relative}")
        actual[relative] = digest
    return actual


def excluded_name(name: str, config: dict[str, Any]) -> bool:
    return name in set(config["excludedBasenames"]) or any(name.endswith(suffix) for suffix in config["excludedSuffixes"])


def validate_top_level(root: Path, config: dict[str, Any]) -> None:
    names = set(os.listdir(root))
    allowed = set(config["sourceTopLevelAllowlist"])
    excluded = set(config["excludedTopLevel"])
    unknown = names - allowed - excluded
    missing = allowed - names
    overlap = allowed & excluded
    if unknown:
        reject(f"unknown top-level entries STOP: {byte_sorted(unknown)}")
    if missing:
        reject(f"allowlisted top-level entries missing: {byte_sorted(missing)}")
    if overlap:
        reject(f"top-level policy overlap: {byte_sorted(overlap)}", INTERNAL_ERROR)


def open_root_fd(root: Path, label: str) -> int:
    try:
        return r4a.open_absolute_directory_nofollow(root, label)
    except (OSError, r4a.ReleaseUnitError) as error:
        code = error.code if isinstance(error, r4a.ReleaseUnitError) else INVALID_UNSAFE
        reject(f"{label}: {error}", code)


def safe_relative(relative: Path, label: str) -> None:
    if not relative.parts or any(part in {"", ".", ".."} or "/" in part or "\x00" in part for part in relative.parts):
        reject(f"{label} contains an unsafe relative path")


def record_from_info(relative: str, info: os.stat_result, digest: str | None) -> dict[str, Any]:
    return {
        "gid": info.st_gid,
        "hash": digest,
        "mode": mode_text(info.st_mode),
        "mtimeNs": info.st_mtime_ns,
        "nlink": info.st_nlink,
        "path": relative,
        "size": info.st_size if stat.S_ISREG(info.st_mode) else 0,
        "type": "file" if stat.S_ISREG(info.st_mode) else "directory",
        "uid": info.st_uid,
    }


def _walk_fd(
    fd: int,
    relative: Path,
    config: dict[str, Any],
    records: list[dict[str, Any]],
    destination: Path | None,
    *,
    copy_hook: Callable[[Path, int], None] | None = None,
) -> None:
    info = os.fstat(fd)
    relative_text = relative.as_posix()
    if stat.S_ISDIR(info.st_mode):
        records.append(record_from_info(relative_text, info, None))
        if destination is not None:
            destination.mkdir(mode=stat.S_IMODE(info.st_mode), exist_ok=False)
        for name in sorted(os.listdir(fd), key=os.fsencode):
            if excluded_name(name, config):
                continue
            if not name or name in {".", ".."} or "/" in name or "\x00" in name:
                reject(f"unsafe source entry name below {relative_text}")
            try:
                child = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, dir_fd=fd)
            except OSError as error:
                if error.errno in {errno.ELOOP, errno.ENOTDIR}:
                    reject(f"source snapshot rejects symlink: {relative_text}/{name}")
                raise
            try:
                child_info = os.fstat(child)
                if not (stat.S_ISDIR(child_info.st_mode) or stat.S_ISREG(child_info.st_mode)):
                    reject(f"source snapshot rejects special entry: {relative_text}/{name}")
                _walk_fd(
                    child,
                    relative / name,
                    config,
                    records,
                    destination / name if destination is not None else None,
                    copy_hook=copy_hook,
                )
            finally:
                os.close(child)
        if destination is not None:
            os.chmod(destination, stat.S_IMODE(info.st_mode))
        return
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        reject(f"source snapshot requires single-link regular files: {relative_text}")
    before = (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size, info.st_mtime_ns)
    digest = sha256_fd(fd)
    records.append(record_from_info(relative_text, info, digest))
    if destination is not None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        out_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC, stat.S_IMODE(info.st_mode))
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            copied = 0
            while payload := os.read(fd, 1024 * 1024):
                view = memoryview(payload)
                while view:
                    written = os.write(out_fd, view)
                    copied += written
                    view = view[written:]
                if copy_hook is not None:
                    copy_hook(relative, copied)
            os.fchmod(out_fd, stat.S_IMODE(info.st_mode))
        finally:
            os.close(out_fd)
    after_info = os.fstat(fd)
    after = (
        after_info.st_dev,
        after_info.st_ino,
        after_info.st_mode,
        after_info.st_nlink,
        after_info.st_size,
        after_info.st_mtime_ns,
    )
    if after != before or sha256_fd(fd) != digest:
        reject(f"source changed concurrently while snapshotting: {relative_text}", CLEANUP_REQUIRED)


def live_allowlist_records(root: Path, config: dict[str, Any]) -> list[dict[str, Any]]:
    validate_top_level(root, config)
    root_fd = open_root_fd(root, "live workspace")
    records: list[dict[str, Any]] = []
    try:
        for name in config["sourceTopLevelAllowlist"]:
            relative = Path(name)
            safe_relative(relative, "top-level allowlist")
            try:
                fd = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, dir_fd=root_fd)
            except OSError as error:
                reject(f"cannot open allowlisted source {name}: {error}")
            try:
                _walk_fd(fd, relative, config, records, None)
            finally:
                os.close(fd)
    finally:
        os.close(root_fd)
    return sorted(records, key=lambda item: os.fsencode(item["path"]))


def records_digest(records: list[dict[str, Any]]) -> str:
    return sha256_bytes(canonical_bytes(records))


def copy_live_snapshot(
    root: Path,
    destination: Path,
    config: dict[str, Any],
    *,
    copy_hook: Callable[[Path, int], None] | None = None,
) -> list[dict[str, Any]]:
    if os.path.lexists(destination):
        reject("source snapshot destination already exists")
    destination.mkdir(mode=0o700)
    root_fd = open_root_fd(root, "live workspace")
    records: list[dict[str, Any]] = []
    try:
        for name in config["sourceTopLevelAllowlist"]:
            fd = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, dir_fd=root_fd)
            try:
                _walk_fd(fd, Path(name), config, records, destination / name, copy_hook=copy_hook)
            finally:
                os.close(fd)
    finally:
        os.close(root_fd)
    return sorted(records, key=lambda item: os.fsencode(item["path"]))


def copy_grdb_snapshot(root: Path, destination: Path) -> list[dict[str, Any]]:
    source = root / "apps/desktop/.build/checkouts/GRDB.swift"
    if not source.is_dir() or source.is_symlink():
        reject("GRDB 7.11.1 checkout is unavailable", ENVIRONMENT_BLOCKED)
    grdb_config = {
        "excludedBasenames": [".build", ".git", ".gitmodules", "CustomSQLite", "SQLiteCustom", "__pycache__"],
        "excludedSuffixes": [],
    }
    parent_fd = open_root_fd(source.parent, "GRDB checkout parent")
    records: list[dict[str, Any]] = []
    try:
        fd = os.open(source.name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, dir_fd=parent_fd)
        try:
            _walk_fd(fd, Path("GRDB.swift-7.11.1"), grdb_config, records, destination)
        finally:
            os.close(fd)
    finally:
        os.close(parent_fd)
    license_path = destination / "LICENSE"
    if not license_path.is_file() or license_path.is_symlink():
        reject("GRDB snapshot must preserve LICENSE")
    return sorted(records, key=lambda item: os.fsencode(item["path"]))


def scan_secret_tree(
    root: Path,
    label: str,
    allowed_fixture_hashes: dict[str, str] | None = None,
) -> dict[str, int]:
    allowed_fixture_hashes = allowed_fixture_hashes or {}
    files = 0
    bytes_scanned = 0
    for current, directories, names in os.walk(root, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        names.sort(key=os.fsencode)
        for name in directories + names:
            path = Path(current) / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                reject(f"{label} secret scan rejects symlink")
        for name in names:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            if SECRET_NAME_RE.search(name) and name not in {"check-v02-secret-hygiene.sh"}:
                reject(f"{label} sensitive filename rejected: {relative}")
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                reject(f"{label} secret scan requires single-link files: {relative}")
            payload = path.read_bytes()
            files += 1
            bytes_scanned += len(payload)
            if any(pattern.search(payload) for pattern in SECRET_CONTENT_PATTERNS):
                if allowed_fixture_hashes.get(relative) != sha256_bytes(payload):
                    reject(f"{label} high-confidence secret content rejected: {relative}")
    return {"files": files, "bytes": bytes_scanned}


def portable_tree_records(root: Path) -> tuple[list[dict[str, Any]], str]:
    if root.is_symlink() or not root.is_dir():
        reject("portable tree root must be one real directory")
    records: list[dict[str, Any]] = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        for name in directories + files:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                reject(f"portable tree rejects symlink: {relative}")
            if stat.S_ISDIR(info.st_mode):
                records.append({"hash": None, "mode": mode_text(info.st_mode), "path": relative, "size": 0, "type": "directory"})
            elif stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    reject(f"portable tree rejects hardlink: {relative}")
                records.append(
                    {
                        "hash": sha256_file(path),
                        "mode": mode_text(info.st_mode),
                        "path": relative,
                        "size": info.st_size,
                        "type": "file",
                    }
                )
            else:
                reject(f"portable tree rejects special entry: {relative}")
    records.sort(key=lambda item: os.fsencode(item["path"]))
    return records, sha256_bytes(canonical_bytes(records))


def deterministic_tar_gz(source: Path, root_name: str, output: Path) -> str:
    if os.path.lexists(output):
        reject(f"archive output already exists: {output}")
    records, _ = portable_tree_records(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                root_info = tarfile.TarInfo(root_name)
                root_info.type = tarfile.DIRTYPE
                root_info.mode = 0o755
                root_info.uid = root_info.gid = 0
                root_info.uname = root_info.gname = ""
                root_info.mtime = 0
                archive.addfile(root_info)
                for record in records:
                    relative = record["path"]
                    path = source / relative
                    name = f"{root_name}/{relative}"
                    info = tarfile.TarInfo(name)
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    info.mode = int(record["mode"], 8)
                    if record["type"] == "directory":
                        info.type = tarfile.DIRTYPE
                        archive.addfile(info)
                    else:
                        info.type = tarfile.REGTYPE
                        info.size = record["size"]
                        with path.open("rb") as handle:
                            archive.addfile(info, handle)
    os.chmod(output, 0o600)
    return sha256_file(output)


def verify_archive_determinism(source: Path, root_name: str, output: Path, scratch: Path) -> str:
    first_hash = deterministic_tar_gz(source, root_name, output)
    second = scratch / f"{output.name}.second"
    second_hash = deterministic_tar_gz(source, root_name, second)
    if first_hash != second_hash or output.read_bytes() != second.read_bytes():
        reject(f"deterministic archive mismatch: {output.name}", INTERNAL_ERROR)
    return first_hash


def extract_safe_tar_gz(archive_path: Path, expected_root: str, destination_parent: Path) -> Path:
    if os.path.lexists(destination_parent):
        reject("archive extraction parent must not exist")
    destination_parent.mkdir(mode=0o700)
    with tarfile.open(archive_path, mode="r:gz") as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        if names != byte_sorted(names) or not names or names[0] != expected_root:
            reject("archive members must be byte-sorted beneath one exact root")
        for member in members:
            pure = PurePosixPath(member.name)
            if not pure.parts or pure.parts[0] != expected_root or any(part in {"", ".", ".."} for part in pure.parts):
                reject("archive contains an unsafe path")
            if not (member.isdir() or member.isreg()) or member.issym() or member.islnk():
                reject("archive contains a link or special entry")
            relative = Path(*pure.parts[1:])
            target = destination_parent / expected_root / relative
            if member.isdir():
                target.mkdir(mode=member.mode, parents=True, exist_ok=False)
                os.chmod(target, member.mode)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    reject("archive regular member has no payload")
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC, member.mode)
                try:
                    while payload := source.read(1024 * 1024):
                        os.write(fd, payload)
                    os.fchmod(fd, member.mode)
                finally:
                    os.close(fd)
    return destination_parent / expected_root


def archive_roundtrip_digest(archive_path: Path, expected_root: str, review_parent: Path, expected_digest: str) -> str:
    extracted = extract_safe_tar_gz(archive_path, expected_root, review_parent)
    _, digest = portable_tree_records(extracted)
    if digest != expected_digest:
        reject(f"archive roundtrip tree digest mismatch: {archive_path.name}")
    return digest


def patch_package_manifest(source: Path, dependency: Path) -> dict[str, str]:
    manifest = source / "apps/desktop/Package.swift"
    before = sha256_file(manifest)
    text = manifest.read_text(encoding="utf-8")
    remote = '.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")'
    if text.count(remote) != 1:
        reject("Package.swift GRDB remote declaration drifted")
    local = f'.package(name: "GRDB.swift", path: "{dependency}")'
    manifest.write_text(text.replace(remote, local), encoding="utf-8")
    os.chmod(manifest, 0o644)
    after = sha256_file(manifest)
    if before == after or "github.com" in manifest.read_text(encoding="utf-8"):
        reject("audit-local Package.swift patch failed")
    return {"beforeHash": before, "afterHash": after, "replacement": "single-exact-remote-to-audit-local-path"}


def isolated_environment(audit_root: Path, prefix: str) -> tuple[dict[str, str], dict[str, str]]:
    roots = {
        "home": audit_root / f"{prefix}-home",
        "tmp": audit_root / f"{prefix}-tmp",
        "config": audit_root / f"{prefix}-swiftpm-config",
        "cache": audit_root / f"{prefix}-swiftpm-cache",
        "scratch": audit_root / f"{prefix}-swift-scratch",
        "moduleCache": audit_root / f"{prefix}-module-cache",
        "security": audit_root / f"{prefix}-swiftpm-security",
    }
    for path in roots.values():
        path.mkdir(mode=0o700)
    env = {
        "HOME": str(roots["home"]),
        "TMPDIR": str(roots["tmp"]),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "CLANG_MODULE_CACHE_PATH": str(roots["moduleCache"]),
        "SWIFT_MODULECACHE_PATH": str(roots["moduleCache"]),
        "GIT_TERMINAL_PROMPT": "0",
        "PYTHONDONTWRITEBYTECODE": "1",
        "HTTP_PROXY": "",
        "HTTPS_PROXY": "",
        "ALL_PROXY": "",
        "NO_PROXY": "*",
    }
    return env, {key: str(value) for key, value in roots.items()}


def build_swift_products(source: Path, audit_root: Path) -> tuple[Path, Path, Path, dict[str, Any]]:
    env, roots = isolated_environment(audit_root, "build")
    manifest = source / "apps/desktop/Package.swift"
    manifest_text = manifest.read_text(encoding="utf-8")
    if ".package(url:" in manifest_text or "http://" in manifest_text or "https://" in manifest_text:
        reject("offline build input contains a remote Swift dependency")
    args = [
        SWIFT,
        "build",
        "--package-path",
        str(source / "apps/desktop"),
        "--configuration",
        "release",
        "--disable-sandbox",
        "--disable-netrc",
        "--skip-update",
        "--config-path",
        roots["config"],
        "--cache-path",
        roots["cache"],
        "--security-path",
        roots["security"],
        "--disable-dependency-cache",
        "--scratch-path",
        roots["scratch"],
    ]
    result = command_ok(args, cwd=source, env=env)
    show = command_ok(args + ["--show-bin-path"], cwd=source, env=env)
    bin_path = Path(show.stdout.decode("utf-8").strip())
    app = bin_path / "LinkDigestApp"
    host = bin_path / "LinkDigestNativeHost"
    bundle = bin_path / RESOURCE_BUNDLE
    if not app.is_file() or app.is_symlink() or not os.access(app, os.X_OK):
        reject("Release App build product is missing", ENVIRONMENT_BLOCKED)
    if not host.is_file() or host.is_symlink() or not os.access(host, os.X_OK):
        reject("Release Host build product is missing", ENVIRONMENT_BLOCKED)
    if not bundle.is_dir() or bundle.is_symlink():
        reject("Release resource bundle is missing", ENVIRONMENT_BLOCKED)
    facts = {
        "argv": args,
        "environment": {key: env[key] for key in sorted(env) if key not in {"HOME", "TMPDIR"}} | {"HOME": "audit-isolated", "TMPDIR": "audit-isolated"},
        "gitUsed": False,
        "networkFallback": False,
        "packageManifestRemoteDependencyCount": 0,
        "stdoutHash": sha256_bytes(result.stdout),
    }
    return app, host, bundle, facts


def codesign_display(path: Path) -> tuple[dict[str, Any], str]:
    result = command_ok([CODESIGN, "-dv", "--verbose=4", str(path)])
    text = (result.stdout + result.stderr).decode("utf-8", errors="strict")
    lines = text.splitlines()
    fields: dict[str, list[str]] = {}
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            fields.setdefault(key, []).append(value)
    identifier = fields.get("Identifier", [])
    signature = fields.get("Signature", [])
    cdhash = fields.get("CDHash", [])
    team = fields.get("TeamIdentifier", [])
    authorities = fields.get("Authority", [])
    timestamp = fields.get("Timestamp", [])
    if len(identifier) != 1 or signature != ["adhoc"] or len(cdhash) != 1 or not re.fullmatch(r"[0-9a-f]{40}", cdhash[0]):
        reject("codesign facts do not describe one ad-hoc signature")
    if team not in ([], ["not set"]) or authorities or timestamp:
        reject("ad-hoc signature unexpectedly contains Team/Authority/timestamp")
    if "runtime" in text.lower():
        reject("local-test signature must not claim hardened runtime")
    return {
        "authority": [],
        "cdHash": cdhash[0],
        "identifier": identifier[0],
        "mode": "adhoc",
        "runtimeOption": False,
        "teamID": None,
        "timestamp": None,
    }, sha256_bytes(text.encode("utf-8"))


def sign_and_verify(path: Path, identifier: str, *, bundle: bool) -> dict[str, Any]:
    sign_argv = [CODESIGN, "--force", "--sign", "-", "--timestamp=none", "--identifier", identifier, str(path)]
    command_ok(sign_argv)
    facts, display_hash = codesign_display(path)
    if facts["identifier"] != identifier:
        reject("codesign identifier drifted")
    strict = [CODESIGN, "--verify", "--strict", "--all-architectures", "--verbose=4", str(path)]
    command_ok(strict)
    deep = strict[:-1] + ["--deep", str(path)] if bundle else strict
    if bundle:
        command_ok(deep)
    return {
        **facts,
        "displayOutputHash": display_hash,
        "signArgv": sign_argv[:-1] + ["<artifact>"],
        "strictAllArchitecturesVerified": True,
        "deepVerified": bundle,
    }


def macho_facts(path: Path) -> dict[str, Any]:
    arch = command_ok([LIPO, "-archs", str(path)]).stdout.decode("utf-8").strip().split()
    minimum = r4a.macho_minimum_macos(path)
    if arch != ["arm64"] or minimum != "15.0":
        reject("Mach-O architecture/minimum OS drifted")
    return {"architectures": arch, "minimumMacOS": minimum}


def tool_facts(root: Path, r4a_hashes: dict[str, str]) -> dict[str, Any]:
    tools = [SWIFT, CODESIGN, HDITUTIL, LIPO, OTOOL, SW_VERS, "/usr/bin/python3"]
    hashes: dict[str, str] = {}
    for tool in tools:
        path = Path(tool)
        if not path.exists():
            reject(f"required tool is missing: {tool}", ENVIRONMENT_BLOCKED)
        hashes[tool] = sha256_file(path.resolve(strict=True))
    swift_version = command_ok([SWIFT, "--version"]).stdout.decode("utf-8", errors="strict").strip()
    macos_version = command_ok([SW_VERS, "-productVersion"]).stdout.decode("utf-8", errors="strict").strip()
    script_paths = [
        "scripts/native-host/local_test_release.py",
        "scripts/native-host/local_test_release_check.py",
        "scripts/native-host/package-local-test-dmg.sh",
        "scripts/native-host/check-local-test-release.sh",
        "config/local-test-release.json",
        "scripts/extension_identity_artifact.py",
    ]
    scripts = {relative: sha256_file(root / relative) for relative in script_paths}
    return {
        "formatVersion": 1,
        "macOSVersion": macos_version,
        "pythonVersion": sys.version.split()[0],
        "r4aFrozenHashes": r4a_hashes,
        "scriptHashes": scripts,
        "swiftVersion": swift_version,
        "toolExecutableHashes": hashes,
    }


def extension_artifact_facts(source_root: Path, config: dict[str, Any]) -> dict[str, Any]:
    configured = config["browserExtension"]
    identity = extension_artifact.load_identity(source_root)
    display = extension_artifact.load_display(source_root)
    host = extension_artifact.validate_native_host_binding(source_root, identity)
    extension_artifact.verify_display_wiring(source_root)
    if (
        identity["artifactSource"] != configured["artifactSource"]
        or identity["extensionID"] != configured["extensionID"]
        or identity["version"] != configured["version"]
        or str(extension_artifact.IDENTITY_PATH) != configured["identityConfig"]
        or str(extension_artifact.TEMPLATE_DIRECTORY) != configured["manifestTemplateDirectory"]
    ):
        reject("extension identity does not match the frozen local-test configuration")
    try:
        artifact = extension_artifact.require_exact_configured_artifact(source_root, identity)
    except extension_artifact.IdentityArtifactError as error:
        reject(f"extension artifact set is invalid: {error}")
    if artifact.relative_to(source_root).as_posix() != configured["artifactSource"]:
        reject("extension artifact path does not equal the frozen configuration")
    entries = extension_artifact.verify_zip(artifact, identity, display)
    templates = extension_artifact.verify_templates(
        source_root,
        identity,
        host,
        source_root / configured["manifestTemplateDirectory"],
    )
    app_templates = extension_artifact.verify_app_installer_resources(source_root, identity, host)
    return {
        "artifact": {
            "handoffPath": f"{configured['handoffDirectory']}/{identity['artifactName']}",
            "sha256": extension_artifact.sha256_file(artifact),
            "sourcePath": configured["artifactSource"],
        },
        "extensionID": identity["extensionID"],
        "identity": {
            "sha256": sha256_file(source_root / configured["identityConfig"]),
            "sourcePath": configured["identityConfig"],
        },
        "manifestKeySHA256": extension_artifact.sha256_bytes(str(identity["manifestKey"]).encode("ascii")),
        "manifestTemplates": {
            browser: {
                "handoffPath": f"{configured['handoffDirectory']}/native-host-manifests/{browser}.json",
                "sha256": digest,
                "sourcePath": f"{configured['manifestTemplateDirectory']}/{browser}.json",
            }
            for browser, digest in templates.items()
        },
        "appInstallerTemplateHashes": app_templates,
        "version": identity["version"],
        "zipEntries": entries,
    }


def exact_app_paths(app: Path) -> None:
    if {path.name for path in app.iterdir()} != {"Contents"}:
        reject("App top-level tree is not exact")
    contents = {path.name for path in (app / "Contents").iterdir()}
    if contents != {"Info.plist", "MacOS", "Resources", "_CodeSignature"}:
        reject("signed App Contents tree is not exact")
    if {path.name for path in (app / "Contents/MacOS").iterdir()} != {"LinkDigestApp"}:
        reject("signed App MacOS tree is not exact")
    if {path.name for path in (app / "Contents/Resources").iterdir()} != {RESOURCE_BUNDLE, "NativeHost", APP_ICON_FILE, PLATFORM_ICONS_DIRECTORY, PROVIDER_ICONS_DIRECTORY}:
        reject("signed App Resources tree is not exact")
    host_root = app / "Contents/Resources/NativeHost"
    if {path.name for path in host_root.iterdir()} != {HOST_PACKAGE_NAME}:
        reject("signed App NativeHost tree is not exact")


def verify_info_plist(app: Path, app_config: dict[str, Any]) -> str:
    path = app / "Contents/Info.plist"
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        reject(f"signed App Info.plist invalid: {error}")
    if value != r4a.info_plist(app_config):
        reject("signed App Info.plist drifted from frozen app config")
    return sha256_file(path)


def verify_embedded_browser_support_resources(app: Path, source_root: Path) -> dict[str, Any]:
    identity = extension_artifact.load_identity(source_root)
    host = extension_artifact.validate_native_host_binding(source_root, identity)
    expected = extension_artifact.verify_app_installer_resources(source_root, identity, host)
    bundled = app / "Contents/Resources" / RESOURCE_BUNDLE / "Resources" / "browser-support"
    bundled_templates = bundled / "native-host-manifests"
    actual = extension_artifact.verify_templates(source_root, identity, host, bundled_templates)
    if actual != expected:
        reject("embedded browser-support template hashes drifted from the frozen extension artifact")
    source_integrity = source_root / extension_artifact.APP_INSTALLER_INTEGRITY_PATH
    bundled_integrity = bundled / "manifest-integrity.json"
    if bundled_integrity.is_symlink() or not bundled_integrity.is_file() or sha256_file(bundled_integrity) != sha256_file(source_integrity):
        reject("embedded browser-support integrity descriptor drifted")
    return {
        "integrityHash": sha256_file(bundled_integrity),
        "templateHashes": actual,
    }


def verify_app_bundle(app: Path, source_root: Path, expected_unit: dict[str, Any] | None = None) -> dict[str, Any]:
    app_config = r4a.load_app_config(source_root)
    exact_app_paths(app)
    plist_hash = verify_info_plist(app, app_config)
    icon = r4a.verify_app_icon(app, source_root, app_config)
    platform_icons = verify_platform_icons(app, source_root)
    provider_icons = verify_provider_icons(app, source_root)
    browser_support = verify_embedded_browser_support_resources(app, source_root)
    app_executable = app / "Contents/MacOS/LinkDigestApp"
    package_root = app / "Contents/Resources/NativeHost" / HOST_PACKAGE_NAME
    try:
        package = stable_host.verify_package(package_root, source_root)
    except stable_host.StableHostError as error:
        reject(f"embedded signed Host package failed r1 verifier: {error}")
    host_executable = package_root / package.config["entrypoint"]
    app_signature, _ = codesign_display(app)
    host_signature, _ = codesign_display(host_executable)
    if app_signature["identifier"] != "com.syc.linkdigest" or host_signature["identifier"] != "com.syc.linkdigest.native-host":
        reject("signed App/Host identifiers drifted")
    command_ok([CODESIGN, "--verify", "--strict", "--all-architectures", "--verbose=4", str(host_executable)])
    command_ok([CODESIGN, "--verify", "--strict", "--all-architectures", "--verbose=4", str(app)])
    command_ok([CODESIGN, "--verify", "--strict", "--all-architectures", "--verbose=4", "--deep", str(app)])
    records, digest = portable_tree_records(app)
    result = {
        "app": {
            "bundleIdentifier": app_config["bundleIdentifier"],
            "bundleVersion": app_config["bundleVersion"],
            "browserSupport": browser_support,
            "executableHash": sha256_file(app_executable),
            "icon": icon,
            "platformIcons": platform_icons,
            "providerIcons": provider_icons,
            "machO": macho_facts(app_executable),
            "plistHash": plist_hash,
            "shortVersion": app_config["shortVersion"],
            "signature": app_signature,
            "treeDigest": digest,
            "treeRecords": records,
        },
        "host": {
            "executableHash": sha256_file(host_executable),
            "machO": macho_facts(host_executable),
            "packageDigest": package.package_digest,
            "packageName": package_root.name,
            "signature": host_signature,
        },
    }
    if expected_unit is not None:
        expected_app = expected_unit.get("app")
        if not isinstance(expected_app, dict):
            reject("local-test unit is missing required app facts")
        actual_app = {key: value for key, value in result["app"].items() if key != "treeRecords"}
        # Candidates sealed before the platform-icon fact existed retain an
        # exact, recomputed verification path below. Newly built units must
        # bind it explicitly; this branch never permits an absent mounted fact.
        if "platformIcons" not in expected_app:
            actual_app.pop("platformIcons")
        # Legacy units sealed before provider icon evidence existed remain
        # inspectable, while every newly produced unit binds this exact fact.
        if "providerIcons" not in expected_app:
            actual_app.pop("providerIcons")
        if expected_app != actual_app:
            reject("local-test unit App binding mismatch")
        if expected_unit.get("host") != result["host"]:
            reject("local-test unit Host binding mismatch")
    return result


def verify_platform_icons(app: Path, source_root: Path) -> dict[str, str]:
    """Keep local-test packaging pinned to the same icon-set contract as r4a."""
    if PLATFORM_ICON_FILES != r4a.PLATFORM_ICON_FILES:
        reject("local-test platform icon tuple drifted from release-unit contract")
    embedded_root = app / "Contents/Resources" / PLATFORM_ICONS_DIRECTORY
    source_icons = source_root / "apps/desktop/Assets" / PLATFORM_ICONS_DIRECTORY
    for root, label in ((embedded_root, "embedded"), (source_icons, "source")):
        if root.is_symlink() or not root.is_dir():
            reject(f"{label} platform icon directory is unsafe")
        if tuple(sorted(path.name for path in root.iterdir())) != PLATFORM_ICON_FILES:
            reject(f"{label} platform icon set drifted")
    return r4a.verify_platform_icons(app, source_root)


def verify_provider_icons(app: Path, source_root: Path) -> dict[str, str]:
    """Keep local-test packaging pinned to the same provider icon contract as r4a."""
    if PROVIDER_ICON_FILES != r4a.PROVIDER_ICON_FILES:
        reject("local-test provider icon tuple drifted from release-unit contract")
    embedded_root = app / "Contents/Resources" / PROVIDER_ICONS_DIRECTORY
    source_icons = source_root / "apps/desktop/Assets" / PROVIDER_ICONS_DIRECTORY
    for root, label in ((embedded_root, "embedded"), (source_icons, "source")):
        if root.is_symlink() or not root.is_dir():
            reject(f"{label} provider icon directory is unsafe")
        if tuple(sorted(path.name for path in root.iterdir())) != PROVIDER_ICON_FILES:
            reject(f"{label} provider icon set drifted")
    return r4a.verify_provider_icons(app, source_root)


def local_test_unit_payload(
    config: dict[str, Any],
    source_manifest_hash: str,
    source_manifest: dict[str, Any],
    tools_hash: str,
    app_result: dict[str, Any],
    package_patch: dict[str, str],
    build_facts: dict[str, Any],
    signing_facts: dict[str, Any],
) -> dict[str, Any]:
    return {
        "app": {key: value for key, value in app_result["app"].items() if key != "treeRecords"},
        "build": {
            "gitUsed": False,
            "networkFallback": False,
            "offlineIsolated": True,
            "packageManifestPatch": package_patch,
            "swiftArgv": build_facts["argv"],
        },
        "dependency": {
            "archiveHash": source_manifest["dependency"]["archiveHash"],
            "archiveName": config["grdbArchive"],
            "licenseHash": source_manifest["dependency"]["licenseHash"],
            "treeDigest": source_manifest["dependency"]["treeDigest"],
            "version": config["grdbVersion"],
        },
        "distributionClass": config["distributionClass"],
        "formatVersion": 1,
        "host": app_result["host"],
        "manualTestStatus": "READY_FOR_MANUAL_OPEN",
        "productStatus": "BLOCKED",
        "publicReleaseStatus": "BLOCKED",
        "signingOrder": signing_facts,
        "source": {
            "archiveHash": source_manifest["source"]["archiveHash"],
            "archiveName": config["sourceArchive"],
            "manifestHash": source_manifest_hash,
            "provenance": "live-worktree-snapshot-including-uncommitted-files",
            "treeDigest": source_manifest["source"]["treeDigest"],
        },
        "toolFactsHash": tools_hash,
        "unitID": config["unitID"],
    }


def validate_staging(staging: Path, source_root: Path, expected_unit: dict[str, Any]) -> dict[str, Any]:
    if staging.is_symlink() or not staging.is_dir():
        reject("DMG staging root is unsafe")
    if {path.name for path in staging.iterdir()} != {"LinkDigest.app", LOCAL_TEST_UNIT}:
        reject("DMG tree must be exact: LinkDigest.app + local-test-unit.json")
    unit_path = staging / LOCAL_TEST_UNIT
    info = unit_path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o644:
        reject("local-test-unit.json must be single-link 0644")
    unit = load_json(unit_path, "local-test unit")
    if canonical_bytes(unit) != unit_path.read_bytes() or unit != expected_unit:
        reject("local-test unit is noncanonical or drifted")
    result = verify_app_bundle(staging / "LinkDigest.app", source_root, unit)
    return {"unit": unit, "appResult": result}


def call_r4a(action: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    try:
        return action(*args, **kwargs)
    except r4a.ReleaseUnitError as error:
        reject(str(error), error.code)


def create_verify_dmg(
    staging: Path,
    output: Path,
    audit_root: Path,
    source_root: Path,
    expected_unit: dict[str, Any],
) -> dict[str, Any]:
    if os.path.lexists(output):
        reject("DMG output already exists")
    create_argv = [
        HDITUTIL,
        "create",
        "-volname",
        "LinkDigest",
        "-srcfolder",
        str(staging),
        "-format",
        "UDZO",
        "-fs",
        "HFS+",
        "-nospotlight",
        "-srcowners",
        "on",
        str(output),
    ]
    command_ok(create_argv)
    command_ok([HDITUTIL, "verify", str(output)])
    mount = audit_root / "mount"
    mount.mkdir(mode=0o700)
    attach_argv = [
        HDITUTIL,
        "attach",
        "-readonly",
        "-nobrowse",
        "-noautoopen",
        "-noautofsck",
        "-mount",
        "required",
        "-mountpoint",
        str(mount),
        "-plist",
        str(output),
    ]
    attach = run_command(attach_argv)
    mounted = call_r4a(
        r4a.guarded_attach_operation,
        attach,
        output,
        mount,
        lambda dev: {"dev": dev, "verified": validate_staging(mount, source_root, expected_unit)},
    )
    if not isinstance(mounted, dict):
        reject("readonly DMG verification produced no evidence", INTERNAL_ERROR)
    if not call_r4a(r4a.no_residual_mount, output, mount):
        reject("residual DMG mount remains", CLEANUP_REQUIRED)
    mounted_result = mounted["verified"]
    return {
        "attachArgv": attach_argv[:-1] + ["<dmg>"],
        "createArgv": create_argv[:-1] + ["<dmg>"],
        "devEntryHash": sha256_bytes(mounted["dev"].encode("utf-8")),
        "dmgHash": sha256_file(output),
        "filesystem": "HFS+",
        "format": "UDZO",
        "mountedAppTreeDigest": mounted_result["appResult"]["app"]["treeDigest"],
        "mountedUnitHash": sha256_file(staging / LOCAL_TEST_UNIT),
        "readonlyMountVerified": True,
        "residualMount": False,
    }


def target_probe() -> dict[str, Any]:
    return call_r4a(r4a.probe_targets)


def write_text(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.rstrip() + "\n", encoding="utf-8")
    os.chmod(path, mode)


def handoff_readme(config: dict[str, Any], dmg_hash: str, extension: dict[str, Any]) -> str:
    return f"""# LinkDigest {config['version']} Local Test

这是给 Syc 本机手工真实测试的 **ad-hoc local-test** 候选，不是 Developer ID 发行版，也没有 notarize 或 staple。

## 手工打开

1. 在 Finder 中双击 `{config['dmgName']}` 挂载 DMG。
2. 在挂载窗口中，优先右键 `LinkDigest.app` → **打开**，再确认打开。
3. 如果 macOS 仍拦截，到 **系统设置 → 隐私与安全性**，确认对象确实是 LinkDigest 后使用 **仍要打开 / Open Anyway**。
4. 不要使用 `sudo`，不要关闭 Gatekeeper，也不要清除 quarantine/xattr。

DMG SHA-256：`{dmg_hash}`。可先对照同目录 `SHA256SUMS`。

## 数据写入边界

自动化构建与验证从未启动 App，也没有写真实 HOME、Application Support、UserDefaults、Keychain、socket 或浏览器 profile。Syc 第一次手工启动 App 后，App 会按正常产品行为在真实 `Application Support`、`UserDefaults` 和用户私有 socket 位置创建本地状态；只有 Syc 主动保存 API Key 时才会写 Keychain。

同目录 `{extension['artifact']['handoffPath']}` 是确定性 Chromium 扩展 zip（version `{extension['version']}`，固定 ID `{extension['extensionID']}`）；`extension/native-host-manifests/` 有 Chrome、Brave、Edge 的精确 origin 模板。它们没有安装到任何真实浏览器 profile，模板 path 仍是占位符。当前没有安装 Browser Native Host、manifest 或 receipt；因此只打开 App 可以测试原生 UI、History、导出和设置交互，但没有扩展与 Host 的手工安装时浏览器捕获不可用。BYOK 真实 Provider 未自动测试，是否发送真实请求完全由 Syc 手工决定。

总检步骤与 PRD §11.1 指标记录表见 `ACCEPTANCE_GUIDE.md`；源码入口和组件地图见 `SOURCE_MAP.md`；构建与签名事实见 `BUILD_MANIFEST.json`，限制见 `KNOWN_LIMITATIONS.md`，打不开时见 `TROUBLESHOOTING.md`。
"""


def known_limitations() -> str:
    return """# Known limitations

- 仅构建并验证 `arm64`、macOS 15+。
- App 与 Native Host 只有 ad-hoc 签名；不是 Developer ID，未 notarize、未 staple，也不宣称正式 hardened runtime。
- Gatekeeper 可能显示来源或安全提示；请只使用 Finder 右键打开或系统设置 Open Anyway。
- 主界面的 manual add / clipboard 按钮仍为 disabled，粘贴链接能力未完成。
- Browser Native Host、manifests、receipt 均未安装；候选仅携带固定扩展 ID 的 Chrome/Brave/Edge 模板，真实 Chrome/Edge manifest 不会被读取、修复或写入。
- 没有扩展与 Host 安装时，浏览器捕获不可用。
- BYOK 真实 Provider 未由自动化调用或验证；自动化没有使用真实 API Key。
- 自动化从未启动 App，没有向真实 HOME、Application Support、UserDefaults、Keychain、socket 或浏览器 profile 写入。
- DMG 使用 UDZO/HFS+，同一批次内容有完整 hash 绑定，但不承诺跨构建 byte-identical。
- 这是 `READY_FOR_MANUAL_OPEN` implementation candidate；产品与公开发布状态仍为 `BLOCKED`。
"""


def troubleshooting(config: dict[str, Any]) -> str:
    return f"""# Troubleshooting

## macOS 阻止打开

先确认 DMG 文件名是 `{config['dmgName']}`，并用 `SHA256SUMS` 核对。然后在 Finder 中右键 App → 打开；仍被拦截时使用系统设置的 Open Anyway。不要运行 `sudo`、不要关闭 Gatekeeper、不要执行 `xattr -d` 或递归清除 quarantine。

## App 能开，但浏览器捕获不可用

这是当前候选的已知边界：自动化没有安装 Native Host、浏览器 manifest 或 receipt，真实 Chrome/Edge 固定 manifest 仍 malformed。不要手改真实 profile；后续安装与三浏览器验收需要独立授权和 rollback 合同。

## Provider 连接失败

真实 BYOK Provider 没有自动测试。先只检查 Base URL、模型名和 API 模式；API Key 只应通过 App 主动保存到 Keychain，不要写进日志、截图、仓库或反馈文本。

## 需要回退

退出 App 并弹出 DMG 即可停止本次测试。本候选没有安装 Host/manifest/receipt，也没有自动修改真实浏览器 profile，因此不存在自动化安装回滚。手工启动产生的本地用户数据不要直接删除；如需清理，先另行确认具体范围。
"""


def source_map() -> str:
    return """# Source map

| Area | 修改入口 | 角色与交接 |
|---|---|---|
| SwiftUI UI | `apps/desktop/Sources/LinkDigestApp/` | 接收 Application 服务状态，展示捕获、History、导出、设置与失败解释 |
| Provider / BYOK | `apps/desktop/Sources/LinkDigestCore/ModelRunOrchestrator.swift`、`apps/desktop/Sources/LinkDigestAdapters/` | 经过数据去向授权后，把请求交给 OpenAI-compatible Provider；Key 只交给 Keychain adapter |
| Persistence | `apps/desktop/Sources/LinkDigestPersistence/`、`apps/desktop/Sources/LinkDigestCore/History*` | 将 Capture/Run/History 交给 GRDB/SQLite，保持 migration 与只读恢复边界 |
| Chromium extension | `apps/browser-extension/entrypoints/`、`apps/browser-extension/src/`、`config/extension-identity.json` | 用户主动触发当前页读取，生成版本化 envelope；公开 manifest key 派生固定 ID，确定性 zip 交给 handoff，私钥不进入源码或候选 |
| Native Host / transport | `apps/desktop/Sources/LinkDigestNativeHost/`、`apps/desktop/Sources/LinkDigestTransport/` | 处理 Chromium framing/合同校验，再交给运行中 App 的用户私有 Unix socket |
| Cross-language contracts | `contracts/`、`scripts/sync-contracts.sh` | JSON Schema 与 fixtures 是 Swift/TypeScript 共同真相源 |
| Packaging / local test | `config/local-test-release.json`、`scripts/native-host/local_test_release.py`、`scripts/native-host/local_test_release_check.py` | 冻结 live snapshot，离线构建，inside-out ad-hoc 签名，生成 DMG/handoff 并独立复核 |

完整 live worktree 源码在 `source/LinkDigest-{config['version']}-live-worktree-source.tar.gz`；GRDB 7.11.1 对应源码在 `source/GRDB.swift-7.11.1-source.tar.gz`。两者的路径、mode、size、SHA-256 和 tree digest 由 `source/SOURCE_MANIFEST.json` 绑定。
"""


def third_party_notices(grdb_snapshot: Path) -> str:
    license_text = (grdb_snapshot / "LICENSE").read_text(encoding="utf-8")
    return f"""# Third-party notices

## GRDB.swift 7.11.1

Project: GRDB.swift  
License: MIT  
Source archive in this handoff: `source/GRDB.swift-7.11.1-source.tar.gz`

The following license text is preserved from the audited local GRDB 7.11.1 checkout:

```text
{license_text.rstrip()}
```
"""


def sha256sums(root: Path) -> str:
    lines: list[str] = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        for name in files:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            if relative == "SHA256SUMS":
                continue
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                reject(f"handoff checksum rejects unsafe file: {relative}")
            lines.append(f"{sha256_file(path)}  {relative}")
    return "\n".join(sorted(lines, key=os.fsencode)) + "\n"


def expected_handoff_paths(config: dict[str, Any], extension: dict[str, Any]) -> set[str]:
    return {
        config["dmgName"],
        "README.md",
        "ACCEPTANCE_GUIDE.md",
        "BUILD_MANIFEST.json",
        "SHA256SUMS",
        "KNOWN_LIMITATIONS.md",
        "TROUBLESHOOTING.md",
        "THIRD_PARTY_NOTICES.md",
        "SOURCE_MAP.md",
        f"source/{config['sourceArchive']}",
        f"source/{config['grdbArchive']}",
        f"source/{SOURCE_MANIFEST}",
        f"evidence/{VERIFICATION_REPORT}",
        f"evidence/{APP_TREE}",
        f"evidence/{TOOL_HASHES}",
        extension["artifact"]["handoffPath"],
        *(template["handoffPath"] for template in extension["manifestTemplates"].values()),
    }


def validate_handoff_tree(root: Path, config: dict[str, Any], extension: dict[str, Any]) -> tuple[list[dict[str, Any]], str]:
    records, digest = portable_tree_records(root)
    files = {record["path"] for record in records if record["type"] == "file"}
    directories = {record["path"] for record in records if record["type"] == "directory"}
    if files != expected_handoff_paths(config, extension) or directories != {"evidence", "extension", "extension/native-host-manifests", "source"}:
        reject("handoff tree is not exact")
    checksum_path = root / "SHA256SUMS"
    if checksum_path.read_text(encoding="utf-8") != sha256sums(root):
        reject("SHA256SUMS coverage drifted")
    return records, digest


def build_candidate(audit_root_text: str) -> dict[str, Any]:
    root = repository_root()
    config = load_config(root)
    r4a_hashes = verify_r4a_frozen(root, config)
    audit = validate_new_audit_root(audit_root_text)

    live_before_records = live_allowlist_records(root, config)
    live_before = records_digest(live_before_records)
    audit.mkdir(mode=0o700)
    working = audit / "working"
    working.mkdir(mode=0o700)
    snapshot = working / "live-source"
    dependency_snapshot = working / "GRDB.swift-7.11.1"
    archives = working / "archives"
    archives.mkdir(mode=0o700)
    try:
        copy_live_snapshot(root, snapshot, config)
        live_after_snapshot = records_digest(live_allowlist_records(root, config))
        if live_after_snapshot != live_before:
            reject("live allowlist inventory changed across source snapshot", CLEANUP_REQUIRED)
        copy_grdb_snapshot(root, dependency_snapshot)
        source_secret_scan = scan_secret_tree(
            snapshot, "live source snapshot", config["secretFixtureHashAllowlist"]
        )
        dependency_secret_scan = scan_secret_tree(dependency_snapshot, "GRDB snapshot")
        source_records, source_tree_digest = portable_tree_records(snapshot)
        dependency_records, dependency_tree_digest = portable_tree_records(dependency_snapshot)

        source_archive = archives / config["sourceArchive"]
        dependency_archive = archives / config["grdbArchive"]
        source_archive_hash = verify_archive_determinism(snapshot, config["sourceTreeName"], source_archive, archives)
        dependency_archive_hash = verify_archive_determinism(
            dependency_snapshot, "GRDB.swift-7.11.1", dependency_archive, archives
        )
        archive_roundtrip_digest(
            source_archive,
            config["sourceTreeName"],
            working / "source-roundtrip",
            source_tree_digest,
        )
        archive_roundtrip_digest(
            dependency_archive,
            "GRDB.swift-7.11.1",
            working / "dependency-roundtrip",
            dependency_tree_digest,
        )

        source_manifest = {
            "dependency": {
                "archiveHash": dependency_archive_hash,
                "archiveName": config["grdbArchive"],
                "licenseHash": sha256_file(dependency_snapshot / "LICENSE"),
                "records": dependency_records,
                "secretScan": dependency_secret_scan,
                "treeDigest": dependency_tree_digest,
                "version": config["grdbVersion"],
            },
            "formatVersion": 1,
            "source": {
                "archiveHash": source_archive_hash,
                "archiveName": config["sourceArchive"],
                "liveAllowlistInventory": live_before,
                "provenance": "live-worktree-snapshot-including-uncommitted-files",
                "records": source_records,
                "secretScan": source_secret_scan,
                "treeDigest": source_tree_digest,
            },
        }
        source_manifest_path = archives / SOURCE_MANIFEST
        write_canonical(source_manifest_path, source_manifest)
        source_manifest_hash = sha256_file(source_manifest_path)

        live_final_prebuild = records_digest(live_allowlist_records(root, config))
        if live_final_prebuild != live_before:
            reject("live allowlist inventory changed before final build", CLEANUP_REQUIRED)

        build_source = extract_safe_tar_gz(
            source_archive, config["sourceTreeName"], working / "build-source-extracted"
        )
        build_dependency = extract_safe_tar_gz(
            dependency_archive, "GRDB.swift-7.11.1", working / "build-dependency-extracted"
        )
        if portable_tree_records(build_source)[1] != source_tree_digest:
            reject("build source does not equal source snapshot")
        if portable_tree_records(build_dependency)[1] != dependency_tree_digest:
            reject("build dependency does not equal GRDB snapshot")
        extension = extension_artifact_facts(build_source, config)
        package_patch = patch_package_manifest(build_source, build_dependency)
        sync_env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        sync_result = command_ok(
            ["/bin/bash", str(build_source / "scripts/sync-contracts.sh")], cwd=build_source, env=sync_env
        )

        tools = tool_facts(root, r4a_hashes)
        tools_path = working / TOOL_HASHES
        write_canonical(tools_path, tools)
        tools_hash = sha256_file(tools_path)

        app_binary, host_binary, resource_bundle, swift_build = build_swift_products(build_source, working)
        host_signing = sign_and_verify(host_binary, config["hostIdentifier"], bundle=False)
        host_package = working / "host-package" / HOST_PACKAGE_NAME
        host_package.parent.mkdir(mode=0o700)
        try:
            stable_host.create_package(host_binary, resource_bundle, host_package, build_source)
            pre_app_package = stable_host.verify_package(host_package, build_source)
        except stable_host.StableHostError as error:
            reject(f"signed Host r1 package failed: {error}")

        staging = working / "dmg-staging"
        staging.mkdir(mode=0o755)
        app_config = r4a.load_app_config(build_source)
        app = r4a.build_app_bundle(
            staging / config["appBundle"], app_binary, resource_bundle, host_package, app_config, build_source
        )
        app_signing = sign_and_verify(app, config["appIdentifier"], bundle=True)
        app_result = verify_app_bundle(app, build_source)
        if app_result["host"]["packageDigest"] != pre_app_package.package_digest:
            reject("outer App sealing changed the signed Host package")
        signing_facts = {
            "hardenedRuntimeClaimed": False,
            "order": ["host-ad-hoc-sign", "r1-package-create-and-verify", "app-assemble", "app-ad-hoc-sign", "r1-package-reverify"],
            "app": app_signing,
            "host": host_signing,
        }
        unit = local_test_unit_payload(
            config,
            source_manifest_hash,
            source_manifest,
            tools_hash,
            app_result,
            package_patch,
            swift_build,
            signing_facts,
        )
        unit_path = staging / LOCAL_TEST_UNIT
        write_canonical(unit_path, unit, 0o644)
        validate_staging(staging, build_source, unit)

        dmg_working = working / config["dmgName"]
        dmg_evidence = create_verify_dmg(staging, dmg_working, audit, build_source, unit)
        probe = target_probe()
        app_tree_evidence = {
            "app": app_result["app"],
            "formatVersion": 1,
            "host": app_result["host"],
        }
        app_tree_path = working / APP_TREE
        write_canonical(app_tree_path, app_tree_evidence)
        verification = {
            "appDeepVerified": True,
            "appStrictAllArchitecturesVerified": True,
            "automationLaunchedAppOrExecutable": False,
            "automationNetworkUsed": False,
            "automationRealHomeWrites": False,
            "dmg": dmg_evidence,
            "formatVersion": 1,
            "hostPackageReverifiedAfterAppSeal": True,
            "hostStrictAllArchitecturesVerified": True,
            "installPerformed": False,
            "manualTestStatus": "READY_FOR_MANUAL_OPEN",
            "productStatus": "BLOCKED",
            "publicReleaseStatus": "BLOCKED",
            "sourceArchiveDeterministicTwice": True,
            "sourceArchiveRoundtripVerified": True,
            "targetProbe": probe,
        }
        verification_path = working / VERIFICATION_REPORT
        write_canonical(verification_path, verification)

        candidate = audit / config["handoffDirectory"]
        (candidate / "source").mkdir(parents=True, mode=0o755)
        (candidate / "evidence").mkdir(mode=0o755)
        (candidate / "extension" / "native-host-manifests").mkdir(parents=True, mode=0o755)
        shutil.copyfile(dmg_working, candidate / config["dmgName"], follow_symlinks=False)
        os.chmod(candidate / config["dmgName"], 0o644)
        for source_file, destination in (
            (source_archive, candidate / "source" / config["sourceArchive"]),
            (dependency_archive, candidate / "source" / config["grdbArchive"]),
            (source_manifest_path, candidate / "source" / SOURCE_MANIFEST),
            (verification_path, candidate / "evidence" / VERIFICATION_REPORT),
            (app_tree_path, candidate / "evidence" / APP_TREE),
            (tools_path, candidate / "evidence" / TOOL_HASHES),
        ):
            shutil.copyfile(source_file, destination, follow_symlinks=False)
            os.chmod(destination, 0o644)
        extension_source = build_source / extension["artifact"]["sourcePath"]
        extension_destination = candidate / extension["artifact"]["handoffPath"]
        shutil.copyfile(extension_source, extension_destination, follow_symlinks=False)
        os.chmod(extension_destination, 0o644)
        for browser, template in extension["manifestTemplates"].items():
            source_template = build_source / template["sourcePath"]
            destination_template = candidate / template["handoffPath"]
            shutil.copyfile(source_template, destination_template, follow_symlinks=False)
            os.chmod(destination_template, 0o644)
        acceptance_guide_source = build_source / config["acceptanceGuideSource"]
        if acceptance_guide_source.is_symlink() or not acceptance_guide_source.is_file():
            reject("acceptance guide source is missing or unsafe")
        shutil.copyfile(acceptance_guide_source, candidate / "ACCEPTANCE_GUIDE.md", follow_symlinks=False)
        os.chmod(candidate / "ACCEPTANCE_GUIDE.md", 0o644)
        write_text(candidate / "README.md", handoff_readme(config, dmg_evidence["dmgHash"], extension))
        write_text(candidate / "KNOWN_LIMITATIONS.md", known_limitations())
        write_text(candidate / "TROUBLESHOOTING.md", troubleshooting(config))
        write_text(candidate / "THIRD_PARTY_NOTICES.md", third_party_notices(dependency_snapshot))
        write_text(candidate / "SOURCE_MAP.md", source_map())

        payload_hashes: dict[str, str] = {}
        for current, directories, files in os.walk(candidate, topdown=True, followlinks=False):
            directories.sort(key=os.fsencode)
            files.sort(key=os.fsencode)
            for name in files:
                path = Path(current) / name
                relative = path.relative_to(candidate).as_posix()
                payload_hashes[relative] = sha256_file(path)
        build_manifest = {
            "app": {key: value for key, value in app_result["app"].items() if key != "treeRecords"},
            "acceptanceGuide": {
                "sha256": sha256_file(acceptance_guide_source),
                "sourcePath": config["acceptanceGuideSource"],
            },
            "build": {
                **swift_build,
                "packageManifestPatch": package_patch,
                "syncContractsStdoutHash": sha256_bytes(sync_result.stdout),
            },
            "distributionClass": config["distributionClass"],
            "dmg": dmg_evidence,
            "browserExtension": extension,
            "formatVersion": 1,
            "gitUsed": False,
            "host": app_result["host"],
            "localTestUnitHash": sha256_file(unit_path),
            "manualTestStatus": "READY_FOR_MANUAL_OPEN",
            "payloadHashesBeforeManifest": payload_hashes,
            "productStatus": "BLOCKED",
            "publicReleaseStatus": "BLOCKED",
            "signing": signing_facts,
            "source": {
                "dependencyArchiveHash": dependency_archive_hash,
                "liveInventoryAfterSnapshot": live_after_snapshot,
                "liveInventoryBefore": live_before,
                "liveInventoryFinalPrebuild": live_final_prebuild,
                "manifestHash": source_manifest_hash,
                "provenance": "live-worktree-snapshot-including-uncommitted-files",
                "sourceArchiveHash": source_archive_hash,
            },
            "targetProbe": probe,
            "toolFactsHash": tools_hash,
        }
        write_canonical(candidate / "BUILD_MANIFEST.json", build_manifest, 0o644)
        (candidate / "SHA256SUMS").write_text(sha256sums(candidate), encoding="utf-8")
        os.chmod(candidate / "SHA256SUMS", 0o644)
        candidate_records, candidate_digest = validate_handoff_tree(candidate, config, extension)
        final_report = {
            "assertions": {
                "appAdHocSigned": True,
                "candidateTreeExact": True,
                "dmgReadonlyMountedAndDetached": True,
                "extensionArtifactBound": True,
                "gitUsed": False,
                "hostAdHocSignedBeforePackage": True,
                "liveInventoryStable": True,
                "noAppLaunch": True,
                "noInstall": True,
                "noNetworkFallback": True,
                "sourceArchivesDeterministicAndRoundtripped": True,
            },
            "auditRoot": str(audit),
            "candidateDigest": candidate_digest,
            "candidatePath": str(candidate),
            "candidateRecords": candidate_records,
            "dmgHash": dmg_evidence["dmgHash"],
            "engineeringStatus": "implementation-candidate",
            "formatVersion": 1,
            "manualTestStatus": "READY_FOR_MANUAL_OPEN-candidate",
            "productStatus": "BLOCKED",
            "publicReleaseStatus": "BLOCKED",
            "reviewStatus": "PENDING_INDEPENDENT_REVIEW",
        }
        write_canonical(audit / "r4b-engineering-report.json", final_report)
        return final_report
    except BaseException:
        # Preserve every success/failure audit.  Never remove or overwrite it.
        raise


def check_config(root_text: str | None = None) -> dict[str, Any]:
    root = Path(root_text) if root_text else repository_root()
    config = load_config(root)
    frozen = verify_r4a_frozen(root, config)
    validate_top_level(root, config)
    extension = extension_artifact_facts(root, config)
    return {"config": "OK", "extension": extension, "r4aFrozenHashes": frozen}


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build")
    build.add_argument("--audit-root", required=True)
    check = subparsers.add_parser("check-config")
    check.add_argument("--root")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_arguments(argv or sys.argv[1:])
    try:
        if args.command == "build":
            print(canonical_bytes(build_candidate(args.audit_root)).decode("utf-8"), end="")
        else:
            print(canonical_bytes(check_config(args.root)).decode("utf-8"), end="")
        return SUCCESS
    except LocalTestError as error:
        print(f"local-test-release: {error}", file=sys.stderr)
        return error.code
    except r4a.ReleaseUnitError as error:
        print(f"local-test-release: r4a helper: {error}", file=sys.stderr)
        return error.code
    except stable_host.StableHostError as error:
        print(f"local-test-release: r1 helper: {error}", file=sys.stderr)
        return INVALID_UNSAFE
    except BaseException as error:
        print(f"local-test-release: internal error: {error}", file=sys.stderr)
        return INTERNAL_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
