#!/usr/bin/env python3
"""Stable Native Host package, manifest, and clean-room install primitives.

This module intentionally uses only the Python standard library.  The install
subcommand is hard-gated to a dedicated clean-room beneath the system temporary
directory; it has no real-HOME or uninstall mode.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable, Sequence


CONFIG_RELATIVE = Path("config/native-host.json")
# universal 二进制：Apple Silicon 与 Intel 各一份切片。
#
# 只发 arm64 会让 2020 年前的 Intel Mac 完全无法运行，而且弹出的报错和
# 「无法验证开发者」长得不一样，用户无从判断。顺序是这里的规范写法；与
# `lipo -archs` 的实际输出比较时必须排序后再比，那条命令不保证顺序。
SUPPORTED_ARCHITECTURES = ["arm64", "x86_64"]
BACKGROUND_RELATIVE = Path("apps/browser-extension/src/entrypoints/background.ts")
PACKAGE_METADATA = "package.json"
CHECKSUMS = "SHA256SUMS"
CLEAN_ROOM_PREFIX = "linkdigest-host-clean-room."
CLEAN_ROOM_SENTINEL = ".linkdigest-clean-room-root"
CLEAN_ROOM_SENTINEL_CONTENT = "LinkDigest clean-room session v1\n"
RECEIPT_NAME = "receipt-v1.json"
EXTENSION_ID_RE = re.compile(r"^[a-p]{32}$")
HOST_NAME_RE = re.compile(r'^const HOST_NAME = "([^"]+)";$', re.MULTILINE)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


class StableHostError(RuntimeError):
    pass


def fail(message: str) -> "None":
    raise StableHostError(message)


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"invalid JSON at {path}: {error}")
    if not isinstance(value, dict):
        fail(f"expected a JSON object at {path}")
    return value


def canonical_json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def load_config(root: Path | None = None) -> dict:
    root = root or repository_root()
    config = load_json(root / CONFIG_RELATIVE)
    expected_types = {
        "formatVersion": int,
        "productVersion": str,
        "hostName": str,
        "protocolMajor": int,
        "minimumMacOS": str,
        "architectures": list,
        "entrypoint": str,
        "resourceBundle": str,
        "releaseExtensionIDs": list,
        "releaseExtensionIDsStatus": str,
    }
    if set(config) != set(expected_types):
        fail("native-host config keys do not match the frozen format")
    for key, expected_type in expected_types.items():
        if not isinstance(config[key], expected_type) or isinstance(config[key], bool):
            fail(f"native-host config field {key} has the wrong type")
    if config["formatVersion"] != 1:
        fail("native-host config formatVersion must be 1")
    if config["productVersion"] != "0.2.0":
        fail("native-host productVersion must be 0.2.0 for the current integrated candidate")
    if config["protocolMajor"] != 1:
        fail("native-host protocolMajor must be 1")
    if config["minimumMacOS"] != "15.0":
        fail("native-host minimumMacOS must be 15.0")
    if config["architectures"] != SUPPORTED_ARCHITECTURES:
        fail(f"native-host architectures must be exactly {SUPPORTED_ARCHITECTURES}")
    for key in ("entrypoint", "resourceBundle"):
        name = config[key]
        if not name or name in (".", "..") or "/" in name or "\\" in name:
            fail(f"native-host config field {key} must be one safe basename")
    if not re.fullmatch(r"[a-z0-9]+(?:\.[a-z0-9]+)+", config["hostName"]):
        fail("native-host hostName has an invalid format")
    release_ids = config["releaseExtensionIDs"]
    if any(not isinstance(item, str) or not EXTENSION_ID_RE.fullmatch(item) for item in release_ids):
        fail("native-host releaseExtensionIDs contains an invalid ID")
    if len(set(release_ids)) != len(release_ids):
        fail("native-host releaseExtensionIDs must not contain duplicates")
    if release_ids:
        if config["releaseExtensionIDsStatus"] != "frozen":
            fail("non-empty releaseExtensionIDs require status=frozen")
    elif config["releaseExtensionIDsStatus"] != "not-frozen":
        fail("empty releaseExtensionIDs must explicitly use status=not-frozen")
    return config


def check_config_sync(root: Path | None = None) -> None:
    root = root or repository_root()
    config = load_config(root)
    background = (root / BACKGROUND_RELATIVE).read_text(encoding="utf-8")
    matches = HOST_NAME_RE.findall(background)
    if matches != [config["hostName"]]:
        fail(
            "browser background HOST_NAME must appear exactly once and equal "
            f"config/native-host.json ({config['hostName']})"
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def path_mode(path: Path) -> int:
    return stat.S_IMODE(path.lstat().st_mode)


def package_metadata(config: dict) -> dict:
    return {
        "architectures": config["architectures"],
        "entrypoint": config["entrypoint"],
        "formatVersion": config["formatVersion"],
        "hostName": config["hostName"],
        "minimumMacOS": config["minimumMacOS"],
        "productVersion": config["productVersion"],
        "protocolMajor": config["protocolMajor"],
        "resourceBundle": config["resourceBundle"],
    }


def safe_relative(path_text: str) -> PurePosixPath:
    if not path_text or "\x00" in path_text or "\n" in path_text or "\r" in path_text or "\\" in path_text:
        fail("checksum path contains unsafe characters")
    path = PurePosixPath(path_text)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail(f"checksum path is not safe: {path_text}")
    return path


def walk_package(root: Path) -> tuple[list[Path], list[Path]]:
    directories: list[Path] = []
    files: list[Path] = []

    def walk(directory: Path) -> None:
        directories.append(directory)
        with os.scandir(directory) as entries:
            for entry in sorted(entries, key=lambda item: os.fsencode(item.name)):
                entry_path = Path(entry.path)
                entry_stat = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(entry_stat.st_mode):
                    fail(f"package contains a symlink: {entry_path.relative_to(root)}")
                if stat.S_ISDIR(entry_stat.st_mode):
                    if entry_stat.st_uid != os.geteuid():
                        fail(f"package directory owner mismatch: {entry_path.relative_to(root)}")
                    walk(entry_path)
                elif stat.S_ISREG(entry_stat.st_mode):
                    if entry_stat.st_uid != os.geteuid() or entry_stat.st_nlink != 1:
                        fail(f"package file owner/link-count is unsafe: {entry_path.relative_to(root)}")
                    files.append(entry_path)
                else:
                    fail(f"package contains a non-regular entry: {entry_path.relative_to(root)}")

    root_stat = root.lstat()
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        fail("package root must be a real directory, not a symlink")
    if root_stat.st_uid != os.geteuid():
        fail("package root owner mismatch")
    walk(root)
    return directories, files


def expected_checksum_files(package_root: Path, files: Sequence[Path]) -> list[str]:
    return sorted(
        (
            path.relative_to(package_root).as_posix()
            for path in files
            if path.relative_to(package_root).as_posix() != CHECKSUMS
        ),
        key=os.fsencode,
    )


def read_checksums(path: Path) -> tuple[dict[str, str], bytes]:
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("SHA256SUMS must be UTF-8")
    checksums: dict[str, str] = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            fail("SHA256SUMS contains a malformed line")
        digest, path_text = match.groups()
        safe_relative(path_text)
        if path_text in checksums:
            fail(f"SHA256SUMS contains a duplicate path: {path_text}")
        checksums[path_text] = digest
    if not checksums:
        fail("SHA256SUMS must not be empty")
    canonical = "".join(f"{checksums[name]}  {name}\n" for name in sorted(checksums, key=os.fsencode)).encode("utf-8")
    if raw != canonical:
        fail("SHA256SUMS order or formatting is not canonical")
    return checksums, raw


def bundle_resource(bundle: Path, relative: str) -> Path | None:
    """在资源包里定位一个资源，兼容两种磁盘布局。

    SwiftPM 单架构构建产出扁平包（`<bundle>/Resources/…`），而多架构 universal
    构建产出标准 macOS 包（`<bundle>/Contents/Resources/Resources/…`）。两者对
    Foundation 的 `Bundle` API 完全等价——`resourceURL` 会各自解析到正确位置，
    所以 App 运行时不受影响；受影响的只有像这里一样按磁盘路径硬找的校验代码。

    符号链接一律拒绝：包内资源必须是真实文件，不能指向包外。
    """
    for prefix in ("Contents/Resources/Resources", "Resources"):
        candidate = bundle / prefix / relative
        if candidate.is_file() and not candidate.is_symlink():
            return candidate
    return None


def macho_architectures(executable: Path) -> list[str]:
    result = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(executable)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        fail("native Host is not a valid Mach-O executable")
    architectures = result.stdout.strip().split()
    if not architectures:
        fail("native Host Mach-O has no architectures")
    return architectures


@dataclass(frozen=True)
class VerifiedPackage:
    root: Path
    config: dict
    metadata: dict
    checksums: dict[str, str]
    package_digest: str


def verify_package(
    package_root: Path,
    root: Path | None = None,
    *,
    expected_product_version: str | None = None,
) -> VerifiedPackage:
    root = root or repository_root()
    config = load_config(root)
    check_config_sync(root)
    package_root = require_canonical_absolute(package_root, "--package-root", must_exist=True)
    directories, files = walk_package(package_root)
    top_level = {path.name for path in package_root.iterdir()}
    expected_top = {PACKAGE_METADATA, CHECKSUMS, config["entrypoint"], config["resourceBundle"]}
    if top_level != expected_top:
        fail(f"package top-level entries mismatch: expected {sorted(expected_top)}")
    expected_bundle = package_root / config["resourceBundle"]
    if not expected_bundle.is_dir() or expected_bundle.is_symlink():
        fail("package resource bundle is missing")
    schema = bundle_resource(expected_bundle, "contracts/capture-envelope-v1.schema.json")
    if schema is None:
        fail("package contract schema is missing")
    root_schema = root / "contracts/capture-envelope-v1.schema.json"
    if sha256_file(schema) != sha256_file(root_schema):
        fail("package contract schema drifted from the repository root contract")
    for directory in directories:
        if path_mode(directory) != 0o755:
            fail(f"package directory permission must be 0755: {directory.relative_to(package_root) or '.'}")
    for file_path in files:
        expected_mode = 0o755 if file_path == package_root / config["entrypoint"] else 0o644
        if path_mode(file_path) != expected_mode:
            fail(f"package file permission mismatch: {file_path.relative_to(package_root)}")
    metadata = load_json(package_root / PACKAGE_METADATA)
    product_version = config["productVersion"] if expected_product_version is None else expected_product_version
    if not isinstance(product_version, str) or not SEMVER_RE.fullmatch(product_version):
        fail("expected package productVersion must be a safe SemVer")
    expected_metadata = package_metadata(config)
    expected_metadata["productVersion"] = product_version
    if metadata != expected_metadata:
        fail("package metadata does not match canonical native-host config")
    checksums, checksum_bytes = read_checksums(package_root / CHECKSUMS)
    expected_files = expected_checksum_files(package_root, files)
    if list(checksums) != expected_files:
        fail("SHA256SUMS coverage does not exactly match package files")
    for relative, expected_digest in checksums.items():
        actual_digest = sha256_file(package_root / relative)
        if actual_digest != expected_digest:
            fail(f"checksum drift detected: {relative}")
    architectures = macho_architectures(package_root / config["entrypoint"])
    # 排序后比较：`lipo -archs` 的输出顺序由 Mach-O 里 fat header 的排列决定
    # （实测 universal 产物给出的是 "x86_64 arm64"），与配置里的书写顺序无关。
    if sorted(architectures) != sorted(config["architectures"]):
        fail(f"native Host architectures {architectures} do not match config {config['architectures']}")
    return VerifiedPackage(
        root=package_root,
        config=config,
        metadata=metadata,
        checksums=checksums,
        package_digest=hashlib.sha256(checksum_bytes).hexdigest(),
    )


def create_package(host_source: Path, bundle_source: Path, package_root: Path, root: Path | None = None) -> None:
    root = root or repository_root()
    config = load_config(root)
    check_config_sync(root)
    host_source = require_canonical_absolute(host_source, "--host-source", must_exist=True)
    bundle_source = require_canonical_absolute(bundle_source, "--bundle-source", must_exist=True)
    package_root = require_canonical_absolute(package_root, "--package-root", must_exist=False)
    if os.path.lexists(package_root):
        fail("package output already exists")
    if host_source.is_symlink() or not host_source.is_file() or not os.access(host_source, os.X_OK):
        fail("--host-source must be a real executable file")
    if bundle_source.is_symlink() or not bundle_source.is_dir():
        fail("--bundle-source must be a real resource bundle directory")
    if host_source.name != config["entrypoint"] or bundle_source.name != config["resourceBundle"]:
        fail("build products do not match canonical entrypoint/resourceBundle names")
    parent = package_root.parent
    if parent.resolve(strict=True) != parent or parent.is_symlink():
        fail("package output parent must be canonical and contain no symlink components")
    package_root.mkdir(mode=0o755)
    try:
        shutil.copyfile(host_source, package_root / config["entrypoint"], follow_symlinks=False)
        os.chmod(package_root / config["entrypoint"], 0o755)

        def copy_bundle(source: Path, destination: Path) -> None:
            destination.mkdir(mode=0o755)
            for entry in sorted(source.iterdir(), key=lambda path: os.fsencode(path.name)):
                target = destination / entry.name
                info = entry.lstat()
                if stat.S_ISLNK(info.st_mode):
                    fail(f"resource bundle contains a symlink: {entry}")
                if stat.S_ISDIR(info.st_mode):
                    copy_bundle(entry, target)
                elif stat.S_ISREG(info.st_mode):
                    shutil.copyfile(entry, target, follow_symlinks=False)
                    os.chmod(target, 0o644)
                else:
                    fail(f"resource bundle contains a non-regular entry: {entry}")
            os.chmod(destination, 0o755)

        copy_bundle(bundle_source, package_root / config["resourceBundle"])
        (package_root / PACKAGE_METADATA).write_bytes(canonical_json_bytes(package_metadata(config)))
        os.chmod(package_root / PACKAGE_METADATA, 0o644)
        _, files = walk_package(package_root)
        names = expected_checksum_files(package_root, files)
        checksum_bytes = "".join(
            f"{sha256_file(package_root / name)}  {name}\n" for name in names
        ).encode("utf-8")
        (package_root / CHECKSUMS).write_bytes(checksum_bytes)
        os.chmod(package_root / CHECKSUMS, 0o644)
        os.chmod(package_root, 0o755)
        verify_package(package_root, root)
    except BaseException:
        shutil.rmtree(package_root, ignore_errors=True)
        raise


def normalize_extension_ids(ids: Iterable[str]) -> list[str]:
    normalized = sorted(set(ids))
    if not normalized:
        fail("at least one extension ID is required")
    for extension_id in normalized:
        if not EXTENSION_ID_RE.fullmatch(extension_id):
            fail(f"invalid Chromium extension ID: {extension_id}")
    return normalized


def render_manifest(config: dict, host_path: Path, mode: str, extension_ids: Sequence[str]) -> bytes:
    host_path = require_canonical_absolute(host_path, "--host-path", must_exist=False)
    if mode == "release":
        if extension_ids:
            fail("release manifest mode does not accept test extension IDs")
        if config["releaseExtensionIDsStatus"] != "frozen" or not config["releaseExtensionIDs"]:
            fail("release extension IDs are not frozen; release manifest generation is fail-closed")
        ids = normalize_extension_ids(config["releaseExtensionIDs"])
    elif mode == "test":
        ids = normalize_extension_ids(extension_ids)
    else:
        fail("manifest mode must be test or release")
    payload = {
        "allowed_origins": [f"chrome-extension://{extension_id}/" for extension_id in ids],
        "description": "LinkDigest Native Messaging Host",
        "name": config["hostName"],
        "path": str(host_path),
        "type": "stdio",
    }
    return canonical_json_bytes(payload)


def require_canonical_absolute(path: Path, label: str, must_exist: bool) -> Path:
    text = str(path)
    if not text.startswith("/") or text == "/" or text.endswith("/"):
        fail(f"{label} must be a non-root canonical absolute path")
    if "//" in text or "/./" in text or "/../" in text or text.endswith("/.") or text.endswith("/.."):
        fail(f"{label} must not contain empty, . or .. components")
    if any(part in ("", ".", "..") for part in PurePosixPath(text).parts[1:]):
        fail(f"{label} must not contain empty, . or .. components")
    if must_exist and not os.path.lexists(text):
        fail(f"{label} must exist")
    if must_exist and Path(text).resolve(strict=True) != Path(text):
        fail(f"{label} must already be canonical and contain no symlink components")
    return Path(text)


def assert_real_directories_from_root(path: Path, label: str) -> None:
    current = Path("/")
    for component in path.parts[1:]:
        current = current / component
        try:
            info = current.lstat()
        except FileNotFoundError:
            fail(f"{label} path component does not exist: {current}")
        if stat.S_ISLNK(info.st_mode):
            fail(f"{label} contains a symlink path component: {current}")
        if not stat.S_ISDIR(info.st_mode):
            fail(f"{label} path component is not a directory: {current}")


def assert_existing_path_prefix_is_safe(path: Path, label: str) -> None:
    """Reject symlinks/non-directories before the first missing component."""
    current = Path("/")
    for component in path.parts[1:]:
        current = current / component
        if not os.path.lexists(current):
            return
        info = current.lstat()
        if stat.S_ISLNK(info.st_mode):
            fail(f"{label} contains a symlink path component: {current}")
        if current != path and not stat.S_ISDIR(info.st_mode):
            fail(f"{label} path component is not a directory: {current}")


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


@dataclass(frozen=True)
class CleanRoom:
    session_root: Path
    home_root: Path


def validate_clean_room(session_root: Path, home_root: Path) -> CleanRoom:
    session_root = require_canonical_absolute(session_root, "--session-root", must_exist=True)
    home_root = require_canonical_absolute(home_root, "--home-root", must_exist=True)
    assert_real_directories_from_root(session_root, "session root")
    assert_real_directories_from_root(home_root, "home root")
    if not session_root.name.startswith(CLEAN_ROOM_PREFIX):
        fail(f"session root basename must start with {CLEAN_ROOM_PREFIX}")
    if not home_root.name.startswith(CLEAN_ROOM_PREFIX):
        fail(f"home root basename must start with {CLEAN_ROOM_PREFIX}")
    if home_root.parent != session_root:
        fail("home root must be a direct child of the dedicated session root")
    sentinel = session_root / CLEAN_ROOM_SENTINEL
    if sentinel.is_symlink() or not sentinel.is_file():
        fail(f"clean-room sentinel is missing: {sentinel}")
    if sentinel.read_text(encoding="utf-8") != CLEAN_ROOM_SENTINEL_CONTENT:
        fail("clean-room sentinel content is invalid")
    actual_home = Path(os.environ.get("HOME", str(Path.home()))).expanduser().resolve()
    if home_root == actual_home or session_root == actual_home or is_within(actual_home, session_root):
        fail("clean-room roots must not be the real HOME")
    allowed_tmp_root = Path("/private/tmp")
    if allowed_tmp_root.is_symlink() or not allowed_tmp_root.is_dir() or allowed_tmp_root.resolve(strict=True) != allowed_tmp_root:
        fail("canonical system temporary root /private/tmp is unavailable or unsafe")
    assert_real_directories_from_root(allowed_tmp_root, "system temporary root")
    if not is_within(session_root, allowed_tmp_root):
        fail("session root must stay inside fixed canonical /private/tmp")
    return CleanRoom(session_root=session_root, home_root=home_root)


def ensure_edge_profile(clean_room: CleanRoom, profile: Path) -> Path:
    profile = require_canonical_absolute(profile, "--edge-user-data-dir", must_exist=True)
    assert_real_directories_from_root(profile, "Edge profile")
    if not is_within(profile, clean_room.session_root) or profile in (clean_room.session_root, clean_room.home_root):
        fail("Edge profile must be a dedicated directory inside the clean-room session")
    return profile


def manifest_targets(clean_room: CleanRoom, config: dict, browsers: Sequence[str], edge_profile: Path | None) -> list[Path]:
    browser_set = set(browsers)
    if not browser_set or browser_set - {"chrome", "brave", "edge"}:
        fail("--browser must name chrome, brave, or edge")
    targets: set[Path] = set()
    if "chrome" in browser_set:
        targets.add(
            clean_room.home_root
            / "Library/Application Support/Google/Chrome/NativeMessagingHosts"
            / f"{config['hostName']}.json"
        )
    if "brave" in browser_set:
        targets.add(
            clean_room.home_root
            / "Library/Application Support/Google/Chrome/NativeMessagingHosts"
            / f"{config['hostName']}.json"
        )
    if "edge" in browser_set:
        if edge_profile is None:
            targets.add(
                clean_room.home_root
                / "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
                / f"{config['hostName']}.json"
            )
        else:
            profile = ensure_edge_profile(clean_room, edge_profile)
            targets.add(profile / "NativeMessagingHosts" / f"{config['hostName']}.json")
    elif edge_profile is not None:
        fail("--edge-user-data-dir requires --browser edge")
    for target in targets:
        if not is_within(target, clean_room.session_root):
            fail("manifest target escaped the clean-room session")
        if target.parent.name != "NativeMessagingHosts":
            fail("manifest must be a direct child of NativeMessagingHosts")
    return sorted(targets, key=lambda path: os.fsencode(str(path)))


def installed_file_digest_matches(source: Path, destination: Path) -> bool:
    if destination.is_symlink() or not destination.is_file():
        return False
    return sha256_file(source) == sha256_file(destination)


def installed_tree_matches(package: VerifiedPackage, version_dir: Path) -> bool:
    if version_dir.is_symlink() or not version_dir.is_dir():
        return False
    try:
        source_directories, _ = walk_package(package.root)
        directories, files = walk_package(version_dir)
    except StableHostError:
        return False
    expected_directories = {path.relative_to(package.root).as_posix() for path in source_directories}
    actual_directories = {path.relative_to(version_dir).as_posix() for path in directories}
    if actual_directories != expected_directories:
        return False
    expected_paths = set(package.checksums) | {CHECKSUMS}
    actual_paths = {path.relative_to(version_dir).as_posix() for path in files}
    if actual_paths != expected_paths:
        return False
    for directory in directories:
        if path_mode(directory) != 0o700:
            return False
    for file_path in files:
        relative = file_path.relative_to(version_dir).as_posix()
        expected_mode = 0o755 if relative == package.config["entrypoint"] else 0o600
        if path_mode(file_path) != expected_mode:
            return False
        if not installed_file_digest_matches(package.root / relative, file_path):
            return False
    return True


def read_receipt(path: Path) -> dict | None:
    if not os.path.lexists(path):
        return None
    if path.is_symlink() or not path.is_file() or path_mode(path) != 0o600:
        fail("existing clean-room receipt is unknown or unsafe")
    return load_json(path)


def expected_receipt(package: VerifiedPackage, version_dir: Path, manifests: dict[Path, bytes]) -> dict:
    return {
        "formatVersion": 1,
        "hostName": package.config["hostName"],
        "installedVersion": f"{package.config['productVersion']}-macos-{package.config['architectures'][0]}",
        "packageDigest": package.package_digest,
        "versionDirectory": str(version_dir),
        "ownedManifests": [
            {"path": str(path), "sha256": hashlib.sha256(payload).hexdigest()}
            for path, payload in sorted(manifests.items(), key=lambda item: os.fsencode(str(item[0])))
        ],
    }


def mkdir_owned(path: Path, created_dirs: list[Path]) -> None:
    assert_existing_path_prefix_is_safe(path, "install target")
    missing: list[Path] = []
    current = path
    while not os.path.lexists(current):
        missing.append(current)
        current = current.parent
    if current.is_symlink() or not current.is_dir():
        fail(f"refusing unsafe parent directory: {current}")
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
        created_dirs.append(directory)
    if path.is_symlink() or not path.is_dir():
        fail(f"refusing unsafe install directory: {path}")
    if path_mode(path) != 0o700:
        fail(f"install directory permission must already be 0700: {path}")


def copy_install_tree(source: Path, destination: Path, entrypoint: str, relative: Path = Path(".")) -> None:
    destination.mkdir(mode=0o700)
    for entry in sorted(source.iterdir(), key=lambda path: os.fsencode(path.name)):
        target = destination / entry.name
        child_relative = relative / entry.name
        if entry.is_dir() and not entry.is_symlink():
            copy_install_tree(entry, target, entrypoint, child_relative)
        elif entry.is_file() and not entry.is_symlink():
            shutil.copyfile(entry, target, follow_symlinks=False)
            os.chmod(target, 0o755 if child_relative.as_posix() == entrypoint else 0o600)
        else:
            fail(f"refusing unsafe package entry during install: {entry}")
    os.chmod(destination, 0o700)


def write_exclusive(path: Path, payload: bytes, mode: int) -> None:
    descriptor: int | None = None
    created = False
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        created = True
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.close(descriptor)
        descriptor = None
        os.chmod(path, mode)
    except BaseException:
        if descriptor is not None:
            os.close(descriptor)
        if created and os.path.lexists(path) and not path.is_symlink() and path.is_file():
            path.unlink()
        raise


def remove_owned_path(path: Path) -> None:
    if not os.path.lexists(path):
        return
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)
    else:
        fail(f"refusing to clean unexpected path type: {path}")


def install_clean_room(args: argparse.Namespace) -> str:
    root = repository_root()
    clean_room = validate_clean_room(Path(args.session_root), Path(args.home_root))
    package = verify_package(Path(args.package_root), root)
    edge_profile = Path(args.edge_user_data_dir) if args.edge_user_data_dir else None
    targets = manifest_targets(clean_room, package.config, args.browser, edge_profile)
    install_root = clean_room.home_root / "Library/Application Support/LinkDigest/NativeMessagingHost"
    version_key = f"{package.config['productVersion']}-macos-{package.config['architectures'][0]}"
    version_dir = install_root / "versions" / version_key
    receipt_path = install_root / RECEIPT_NAME
    host_path = version_dir / package.config["entrypoint"]
    manifest_payload = render_manifest(package.config, host_path, "test", args.extension_id)
    manifests = {target: manifest_payload for target in targets}
    receipt = expected_receipt(package, version_dir, manifests)
    receipt_bytes = canonical_json_bytes(receipt)
    assert_existing_path_prefix_is_safe(version_dir, "version target")
    assert_existing_path_prefix_is_safe(receipt_path, "receipt target")
    for target in targets:
        assert_existing_path_prefix_is_safe(target, "manifest target")
    existing_receipt = read_receipt(receipt_path)
    any_existing = os.path.lexists(version_dir) or os.path.lexists(receipt_path) or any(os.path.lexists(path) for path in targets)
    if any_existing:
        if existing_receipt != receipt:
            fail("existing install target is unknown or differs; r1 refuses overwrite/upgrade")
        if not installed_tree_matches(package, version_dir):
            fail("existing version directory differs from the verified package")
        for target, payload in manifests.items():
            if target.is_symlink() or not target.is_file() or path_mode(target) != 0o600 or target.read_bytes() != payload:
                fail("existing manifest differs from the owned receipt")
        return "noop"
    plan = {
        "action": "clean-room-initial-install",
        "dryRun": not args.apply,
        "versionDirectory": str(version_dir),
        "manifestTargets": [str(path) for path in targets],
        "receipt": str(receipt_path),
    }
    if not args.apply:
        print(canonical_json_bytes(plan).decode("utf-8"), end="")
        return "dry-run"

    created_dirs: list[Path] = []
    created_paths: list[Path] = []
    staging = install_root / f".staging-{uuid.uuid4().hex}"
    try:
        mkdir_owned(install_root / "versions", created_dirs)
        if os.path.lexists(staging) or os.path.lexists(version_dir):
            fail("clean-room staging/version target unexpectedly exists")
        copy_install_tree(package.root, staging, package.config["entrypoint"])
        created_paths.append(staging)
        os.rename(staging, version_dir)
        created_paths[-1] = version_dir
        if args.inject_failure == "after-version":
            fail("injected failure after version install")
        for target, payload in manifests.items():
            mkdir_owned(target.parent, created_dirs)
            if os.path.lexists(target):
                fail("manifest appeared during initial install; refusing overwrite")
            write_exclusive(target, payload, 0o600)
            created_paths.append(target)
        if args.inject_failure == "after-manifest":
            fail("injected failure after manifest install")
        if os.path.lexists(receipt_path):
            fail("receipt appeared during initial install; refusing overwrite")
        write_exclusive(receipt_path, receipt_bytes, 0o600)
        created_paths.append(receipt_path)
        if args.inject_failure == "after-receipt":
            fail("injected failure after receipt install")
    except BaseException:
        for path in reversed(created_paths):
            remove_owned_path(path)
        remove_owned_path(staging)
        for directory in reversed(created_dirs):
            try:
                directory.rmdir()
            except OSError:
                pass
        raise
    print(canonical_json_bytes(plan | {"dryRun": False, "result": "installed"}).decode("utf-8"), end="")
    return "installed"


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("check-config")

    verify = subparsers.add_parser("verify-package")
    verify.add_argument("--package-root", required=True)

    create = subparsers.add_parser("create-package")
    create.add_argument("--host-source", required=True)
    create.add_argument("--bundle-source", required=True)
    create.add_argument("--package-root", required=True)

    render = subparsers.add_parser("render-manifest")
    render.add_argument("--host-path", required=True)
    render.add_argument("--mode", choices=("test", "release"), required=True)
    render.add_argument("--extension-id", action="append", default=[])

    install = subparsers.add_parser("clean-room-install")
    install.add_argument("--package-root", required=True)
    install.add_argument("--session-root", required=True)
    install.add_argument("--home-root", required=True)
    install.add_argument("--browser", action="append", required=True)
    install.add_argument("--edge-user-data-dir")
    install.add_argument("--extension-id", action="append", required=True)
    install.add_argument("--apply", action="store_true")
    install.add_argument(
        "--inject-failure",
        choices=("none", "after-version", "after-manifest", "after-receipt"),
        default="none",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_arguments(argv or sys.argv[1:])
    try:
        if args.command == "check-config":
            check_config_sync()
            print("native-host config sync: OK")
        elif args.command == "verify-package":
            package = verify_package(Path(args.package_root))
            print(f"stable package verify: OK ({package.package_digest})")
        elif args.command == "create-package":
            create_package(Path(args.host_source), Path(args.bundle_source), Path(args.package_root))
            print(f"stable package created: {args.package_root}")
        elif args.command == "render-manifest":
            config = load_config()
            check_config_sync()
            sys.stdout.buffer.write(render_manifest(config, Path(args.host_path), args.mode, args.extension_id))
        elif args.command == "clean-room-install":
            result = install_clean_room(args)
            if result == "noop":
                print("clean-room initial install: noop")
        else:
            fail(f"unsupported command: {args.command}")
        return 0
    except StableHostError as error:
        print(f"stable-host: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
