#!/usr/bin/env python3
"""Build and verify the unsigned LinkDigest r4a App + DMG release unit.

The production build is deliberately confined to a caller-created name under
canonical /private/tmp.  The path itself must not exist yet.  Source and the
already-resolved GRDB checkout are copied read-only into that audit root; no
workspace build directory, real HOME target, signature, notarization, or
browser process is touched.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import plistlib
import pwd
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Sequence

sys.dont_write_bytecode = True

import stable_host


SUCCESS = 0
INVALID_UNSAFE = 2
CLEANUP_REQUIRED = 8
BLOCKED = 10
ENVIRONMENT_BLOCKED = 20
INTERNAL_ERROR = 70

AUDIT_PREFIX = "linkdigest-r4a-release."
APP_CONFIG_RELATIVE = Path("config/app-release.json")
APP_BUNDLE = "LinkDigest.app"
RESOURCE_BUNDLE = "LinkDigest_LinkDigestCore.bundle"
APP_ICON_FILE = "AppIcon.icns"
PLATFORM_ICONS_DIRECTORY = "PlatformIcons"
PLATFORM_ICON_FILES = ("bilibili.svg", "douban.svg", "douyin.svg", "github.svg", "juejin.svg", "medium.svg", "reddit.svg", "toutiao.svg", "wechat.svg", "weibo.svg", "x.com.svg", "xiaohongshu.svg", "youtube.svg", "zhihu.svg")
PROVIDER_ICONS_DIRECTORY = "ProviderIcons"
PROVIDER_ICON_FILES = ("bailian.svg", "deepinfra.svg", "deepseek.svg", "groq.svg", "ollama.svg", "openai.svg", "openrouter.svg", "siliconflow.svg", "zhipu.svg")
RELEASE_UNIT_NAME = "release-unit.json"
UNIT_ID = "com.syc.linkdigest.release-unit.v1"
DMG_NAME = "LinkDigest-0.2.0-macos-arm64.dmg"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SEMVER_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*)){0,2}$")
EXTENSION_ID_RE = re.compile(r"^[a-p]{32}$")

SWIFT = "/usr/bin/swift"
HDITUTIL = "/usr/bin/hdiutil"
LIPO = "/usr/bin/lipo"
OTOOL = "/usr/bin/otool"
CODESIGN = "/usr/bin/codesign"

APP_CONFIG_KEYS = {
    "formatVersion",
    "appName",
    "iconFile",
    "executable",
    "bundleIdentifier",
    "bundleIdentifierStatus",
    "shortVersion",
    "bundleVersion",
    "minimumMacOS",
    "architectures",
    "category",
}

INFO_PLIST_KEYS = {
    "CFBundleDevelopmentRegion",
    "CFBundleDisplayName",
    "CFBundleExecutable",
    "CFBundleIconFile",
    "CFBundleIdentifier",
    "CFBundleInfoDictionaryVersion",
    "CFBundleName",
    "CFBundlePackageType",
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "LSApplicationCategoryType",
    "LSMinimumSystemVersion",
    "NSHighResolutionCapable",
}

RELEASE_UNIT_KEYS = {
    "formatVersion",
    "unitID",
    "productStatus",
    "separateAuthorizationRequired",
    "blockers",
    "app",
    "host",
    "signing",
}


class ReleaseUnitError(RuntimeError):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code


def reject(message: str, code: int = INVALID_UNSAFE) -> "None":
    raise ReleaseUnitError(code, message)


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def byte_sorted(values: Iterable[str]) -> list[str]:
    return sorted(values, key=os.fsencode)


def mode_text(mode: int) -> str:
    return f"0{stat.S_IMODE(mode):03o}"


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = path.read_bytes()
        value = json.loads(payload.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        reject(f"{label} is invalid JSON: {error}")
    if not isinstance(value, dict):
        reject(f"{label} must be a JSON object")
    return value


def safe_basename(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value in {".", ".."} or "/" in value or "\\" in value:
        reject(f"{label} must be one safe basename")
    return value


def load_app_config(root: Path | None = None) -> dict[str, Any]:
    root = root or repository_root()
    config = load_json(root / APP_CONFIG_RELATIVE, "app release config")
    if set(config) != APP_CONFIG_KEYS:
        reject("app release config keys do not match the frozen format")
    if type(config["formatVersion"]) is not int or config["formatVersion"] != 1:
        reject("app release formatVersion must be integer 1")
    exact_strings = {
        "appName": "LinkDigest",
        "iconFile": APP_ICON_FILE,
        "executable": "LinkDigestApp",
        "bundleIdentifier": "com.syc.linkdigest",
        "bundleIdentifierStatus": "engineering-candidate",
        "shortVersion": "0.2.0",
        "bundleVersion": "1",
        "minimumMacOS": "15.0",
        "category": "public.app-category.productivity",
    }
    for key, expected in exact_strings.items():
        if type(config[key]) is not str or config[key] != expected:
            reject(f"app release config {key} must be {expected!r}")
    safe_basename(config["appName"], "appName")
    safe_basename(config["iconFile"], "iconFile")
    safe_basename(config["executable"], "executable")
    if not SEMVER_RE.fullmatch(config["shortVersion"]):
        reject("shortVersion must be a strict three-part version")
    if not config["bundleVersion"].isdigit() or config["bundleVersion"].startswith("0"):
        reject("bundleVersion must be a positive canonical decimal string")
    if not VERSION_RE.fullmatch(config["minimumMacOS"]):
        reject("minimumMacOS is invalid")
    if type(config["architectures"]) is not list or config["architectures"] != ["arm64"]:
        reject("architectures must be exactly [arm64]")
    return config


def validate_lexical_absolute(value: str, label: str) -> Path:
    if (
        not isinstance(value, str)
        or not value.startswith("/")
        or value == "/"
        or value.endswith("/")
        or "\x00" in value
        or "\r" in value
        or "\n" in value
        or "//" in value
        or "/./" in value
        or "/../" in value
        or value.endswith("/.")
        or value.endswith("/..")
    ):
        reject(f"{label} must be a non-root canonical absolute path")
    path = Path(value)
    if any(part in {"", ".", ".."} for part in PurePosixPath(value).parts[1:]):
        reject(f"{label} contains an unsafe path component")
    return path


def assert_real_components(path: Path, label: str, *, final_may_be_missing: bool = False) -> None:
    current = Path("/")
    parts = path.parts[1:]
    for index, part in enumerate(parts):
        current /= part
        if not os.path.lexists(current):
            if final_may_be_missing and index == len(parts) - 1:
                return
            reject(f"{label} path component is missing")
        info = current.lstat()
        if stat.S_ISLNK(info.st_mode):
            reject(f"{label} traverses a symlink")
        if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            reject(f"{label} parent component is not a directory")


def validate_new_audit_root(value: str) -> Path:
    path = validate_lexical_absolute(value, "--audit-root")
    if path.parent != Path("/private/tmp") or not path.name.startswith(AUDIT_PREFIX) or len(path.name) <= len(AUDIT_PREFIX):
        reject(f"--audit-root must be a direct child of /private/tmp named {AUDIT_PREFIX}*")
    assert_real_components(path.parent, "audit root parent")
    parent = path.parent
    if parent.resolve(strict=True) != parent:
        reject("/private/tmp is not canonical")
    if os.path.lexists(path):
        reject("--audit-root output must not already exist")
    return path


def validate_existing_audit_root(value: str) -> Path:
    path = validate_lexical_absolute(value, "--audit-root")
    if path.parent != Path("/private/tmp") or not path.name.startswith(AUDIT_PREFIX) or len(path.name) <= len(AUDIT_PREFIX):
        reject(f"--audit-root must be a direct child of /private/tmp named {AUDIT_PREFIX}*")
    assert_real_components(path, "audit root")
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        reject("existing audit root must be a current-user-owned 0700 directory")
    return path


def run_command(
    argv: Sequence[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_bytes: bytes | None = None,
    allowed: set[str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    if not argv or not os.path.isabs(argv[0]):
        reject("subprocess executable must be an absolute path", INTERNAL_ERROR)
    if allowed is not None and argv[0] not in allowed:
        reject("subprocess executable is outside the fixed allowlist", INTERNAL_ERROR)
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
            timeout=1800,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        reject(f"environment could not run {argv[0]}: {error}", ENVIRONMENT_BLOCKED)


def command_ok(argv: Sequence[str], **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
    result = run_command(argv, **kwargs)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).decode("utf-8", errors="replace")[-2000:]
        reject(f"command failed ({result.returncode}): {argv[0]}: {detail}", ENVIRONMENT_BLOCKED)
    return result


def inventory_tree(root: Path, *, include_metadata: bool) -> str:
    digest = hashlib.sha256()
    if not os.path.lexists(root):
        return sha256_bytes(b"absent\n")
    paths = [root]
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        paths.extend(Path(current) / name for name in directories + files)
    unique = sorted(set(paths), key=lambda path: os.fsencode("." if path == root else path.relative_to(root).as_posix()))
    for path in unique:
        info = path.lstat()
        relative = "." if path == root else path.relative_to(root).as_posix()
        kind = stat.S_IFMT(info.st_mode)
        digest.update(f"{relative}\0{kind}\0{mode_text(info.st_mode)}\0{info.st_size}".encode())
        if include_metadata:
            digest.update(f"\0{info.st_uid}\0{info.st_gid}\0{info.st_nlink}\0{info.st_mtime_ns}".encode())
        if stat.S_ISREG(info.st_mode):
            digest.update(f"\0{sha256_file(path)}".encode())
        elif stat.S_ISLNK(info.st_mode):
            digest.update(f"\0{os.readlink(path)}".encode())
        digest.update(b"\n")
    return digest.hexdigest()


O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)


def open_absolute_directory_nofollow(path: Path, label: str) -> int:
    """Open every absolute directory component with openat + O_NOFOLLOW."""
    path = validate_lexical_absolute(str(path), label)
    descriptor = os.open("/", os.O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try:
        for component in path.parts[1:]:
            next_descriptor = os.open(
                component,
                os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
        info = os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
            reject(f"{label} must be a current-user-owned directory")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_relative_nofollow(root_fd: int, relative: Path, label: str) -> tuple[int, os.stat_result]:
    parts = relative.parts
    if not parts or any(part in {"", ".", ".."} or "/" in part for part in parts):
        reject(f"{label} has an unsafe relative path")
    descriptor = os.dup(root_fd)
    try:
        for index, component in enumerate(parts):
            flags = os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            if index < len(parts) - 1:
                flags |= O_DIRECTORY
            else:
                flags |= O_NONBLOCK
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
            info = os.fstat(descriptor)
            if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
                reject(f"{label} parent is not a directory")
        return descriptor, os.fstat(descriptor)
    except OSError as error:
        os.close(descriptor)
        if error.errno in {errno.ELOOP, errno.ENOTDIR}:
            reject(f"{label} contains a symlink or non-directory component")
        raise
    except BaseException:
        os.close(descriptor)
        raise


def copy_regular_fd(source_fd: int, source_info: os.stat_result, destination: Path, label: str) -> None:
    if not stat.S_ISREG(source_info.st_mode) or source_info.st_nlink != 1:
        reject(f"{label} must be a single-link regular file")
    destination_fd = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        stat.S_IMODE(source_info.st_mode),
    )
    try:
        os.lseek(source_fd, 0, os.SEEK_SET)
        while payload := os.read(source_fd, 1024 * 1024):
            view = memoryview(payload)
            while view:
                written = os.write(destination_fd, view)
                view = view[written:]
        os.fchmod(destination_fd, stat.S_IMODE(source_info.st_mode))
        final_source = os.fstat(source_fd)
        if (
            final_source.st_dev,
            final_source.st_ino,
            final_source.st_mode,
            final_source.st_nlink,
            final_source.st_size,
            final_source.st_mtime_ns,
        ) != (
            source_info.st_dev,
            source_info.st_ino,
            source_info.st_mode,
            source_info.st_nlink,
            source_info.st_size,
            source_info.st_mtime_ns,
        ):
            reject(f"{label} changed while being copied")
    finally:
        os.close(destination_fd)


def copy_directory_fd(
    source_fd: int,
    destination: Path,
    *,
    excluded_names: set[str],
    label: str,
) -> None:
    source_info = os.fstat(source_fd)
    if not stat.S_ISDIR(source_info.st_mode) or source_info.st_uid != os.geteuid():
        reject(f"{label} must be a current-user-owned directory")
    destination.mkdir(mode=stat.S_IMODE(source_info.st_mode))
    for name in sorted(os.listdir(source_fd), key=os.fsencode):
        if name in excluded_names:
            continue
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            reject(f"{label} contains an unsafe entry name")
        try:
            child_fd = os.open(
                name,
                os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                dir_fd=source_fd,
            )
        except OSError as error:
            if error.errno in {errno.ELOOP, errno.ENOTDIR}:
                reject(f"{label} contains a symlink: {name}")
            raise
        try:
            child_info = os.fstat(child_fd)
            target = destination / name
            if stat.S_ISDIR(child_info.st_mode):
                copy_directory_fd(
                    child_fd,
                    target,
                    excluded_names=excluded_names,
                    label=f"{label}/{name}",
                )
            elif stat.S_ISREG(child_info.st_mode):
                copy_regular_fd(child_fd, child_info, target, f"{label}/{name}")
            else:
                reject(f"{label} contains a special file: {name}")
        finally:
            os.close(child_fd)
    os.chmod(destination, stat.S_IMODE(source_info.st_mode))


def copy_path_nofollow(
    source_root: Path,
    relative: Path,
    destination: Path,
    *,
    excluded_names: set[str],
    label: str,
) -> None:
    root_fd = open_absolute_directory_nofollow(source_root, f"{label} root")
    try:
        source_fd, source_info = open_relative_nofollow(root_fd, relative, label)
        try:
            if stat.S_ISDIR(source_info.st_mode):
                copy_directory_fd(
                    source_fd,
                    destination,
                    excluded_names=excluded_names,
                    label=label,
                )
            elif stat.S_ISREG(source_info.st_mode):
                destination.parent.mkdir(parents=True, exist_ok=True)
                copy_regular_fd(source_fd, source_info, destination, label)
            else:
                reject(f"{label} is not a regular file or directory")
        finally:
            os.close(source_fd)
    finally:
        os.close(root_fd)


def copy_source(root: Path, destination: Path) -> None:
    destination.mkdir(mode=0o700)
    allowlist = [
        Path("apps/desktop"),
        Path("apps/browser-extension"),
        Path("contracts"),
        Path("config"),
        Path("scripts/sync-contracts.sh"),
        Path("scripts/native-host/stable_host.py"),
    ]

    blocked = {".git", ".build", "node_modules", ".output", "output", "evidence", "DerivedData", "__pycache__"}
    for relative in allowlist:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            copy_path_nofollow(root, relative, target, excluded_names=blocked, label=f"source {relative}")
        except FileNotFoundError:
            reject(f"allowlisted build source is missing: {relative}", ENVIRONMENT_BLOCKED)
    forbidden = {".git", ".build", "node_modules", ".output", "output", "evidence", "__pycache__"}
    for path in destination.rglob("*"):
        if path.name in forbidden:
            reject(f"clean source copied forbidden path: {path.name}", INTERNAL_ERROR)


def copy_grdb(root: Path, destination: Path) -> None:
    relative = Path("apps/desktop/.build/checkouts/GRDB.swift")
    blocked = {".git", ".gitmodules", ".build", "SQLiteCustom", "CustomSQLite", "__pycache__"}
    destination.parent.mkdir(mode=0o700, exist_ok=True)
    try:
        copy_path_nofollow(root, relative, destination, excluded_names=blocked, label="offline GRDB checkout")
    except FileNotFoundError:
        reject("offline GRDB checkout is unavailable", ENVIRONMENT_BLOCKED)
    if not (destination / "Package.swift").is_file() or (destination / ".git").exists():
        reject("audit-local GRDB copy is incomplete", ENVIRONMENT_BLOCKED)


def patch_local_dependency(source: Path, dependency: Path) -> None:
    manifest = source / "apps/desktop/Package.swift"
    text = manifest.read_text(encoding="utf-8")
    remote = '.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")'
    if text.count(remote) != 1:
        reject("Swift package GRDB declaration drifted", INVALID_UNSAFE)
    manifest.write_text(text.replace(remote, f'.package(path: "{dependency}")'), encoding="utf-8")


def sync_contracts(source: Path) -> None:
    result = run_command(
        ["/bin/bash", str(source / "scripts/sync-contracts.sh")],
        cwd=source,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
        allowed={"/bin/bash"},
    )
    if result.returncode != 0:
        reject("temporary-source contract synchronization failed", ENVIRONMENT_BLOCKED)


def build_swift_products(source: Path, audit_root: Path) -> tuple[Path, Path, Path]:
    home = audit_root / "build-home"
    tmp = audit_root / "build-tmp"
    scratch = audit_root / "swift-scratch"
    config = audit_root / "swiftpm-config"
    cache = audit_root / "swiftpm-cache"
    module_cache = audit_root / "module-cache"
    for directory in (home, tmp, scratch, config, cache, module_cache):
        directory.mkdir(mode=0o700)
    env = {
        "HOME": str(home),
        "TMPDIR": str(tmp),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "CLANG_MODULE_CACHE_PATH": str(module_cache),
        "SWIFT_MODULECACHE_PATH": str(module_cache),
        "GIT_TERMINAL_PROMPT": "0",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
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
        str(config),
        "--cache-path",
        str(cache),
        "--scratch-path",
        str(scratch),
    ]
    command_ok(args, cwd=source, env=env, allowed={SWIFT})
    show = command_ok(
        args + ["--show-bin-path"],
        cwd=source,
        env=env,
        allowed={SWIFT},
    )
    bin_path = Path(show.stdout.decode("utf-8").strip())
    app = bin_path / "LinkDigestApp"
    host = bin_path / "LinkDigestNativeHost"
    bundle = bin_path / RESOURCE_BUNDLE
    if not app.is_file() or not os.access(app, os.X_OK):
        reject("Release LinkDigestApp is missing", ENVIRONMENT_BLOCKED)
    if not host.is_file() or not os.access(host, os.X_OK):
        reject("Release LinkDigestNativeHost is missing", ENVIRONMENT_BLOCKED)
    if not bundle.is_dir() or bundle.is_symlink():
        reject("Release LinkDigestCore resource bundle is missing", ENVIRONMENT_BLOCKED)
    return app, host, bundle


def macho_architectures(path: Path) -> list[str]:
    result = command_ok([LIPO, "-archs", str(path)], allowed={LIPO})
    values = result.stdout.decode("utf-8").strip().split()
    if not values:
        reject("Mach-O architecture list is empty")
    return values


def macho_minimum_macos(path: Path) -> str:
    result = command_ok([OTOOL, "-l", str(path)], allowed={OTOOL})
    lines = result.stdout.decode("utf-8", errors="strict").splitlines()
    versions: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_BUILD_VERSION":
            for candidate in lines[index + 1 : index + 8]:
                match = re.match(r"^\s*minos\s+([^ ]+)", candidate)
                if match:
                    versions.append(match.group(1))
                    break
    if len(versions) != 1 or not VERSION_RE.fullmatch(versions[0]):
        reject("Mach-O must contain one parseable LC_BUILD_VERSION minos")
    components = versions[0].split(".")
    while len(components) > 2 and components[-1] == "0":
        components.pop()
    return ".".join(components)


def unsigned_signature_state(app: Path) -> dict[str, Any]:
    result = run_command([CODESIGN, "-dv", "--verbose=4", str(app)], allowed={CODESIGN})
    text = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    authority = [line for line in text.splitlines() if line.startswith("Authority=")]
    team = [line for line in text.splitlines() if line.startswith("TeamIdentifier=") and line != "TeamIdentifier=not set"]
    if authority or team:
        reject("unsigned r4a App unexpectedly carries Developer ID authority or Team ID")
    if (app / "Contents/_CodeSignature").exists():
        reject("unsigned r4a App must not contain _CodeSignature")
    return {"mode": "unsigned", "teamID": None}


def info_plist(config: dict[str, Any]) -> dict[str, Any]:
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": config["appName"],
        "CFBundleExecutable": config["executable"],
        "CFBundleIconFile": Path(config["iconFile"]).stem,
        "CFBundleIdentifier": config["bundleIdentifier"],
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": config["appName"],
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": config["shortVersion"],
        "CFBundleVersion": config["bundleVersion"],
        "LSApplicationCategoryType": config["category"],
        "LSMinimumSystemVersion": config["minimumMacOS"],
        "NSHighResolutionCapable": True,
    }


def write_plist(path: Path, value: dict[str, Any]) -> None:
    payload = plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True)
    path.write_bytes(payload)
    os.chmod(path, 0o644)


def copy_resource_tree(source: Path, destination: Path) -> None:
    copy_path_nofollow(
        source.parent,
        Path(source.name),
        destination,
        excluded_names=set(),
        label="runtime resource bundle",
    )


def build_app_bundle(
    output: Path,
    app_binary: Path,
    resource_bundle: Path,
    host_package: Path,
    app_config: dict[str, Any],
    source_root: Path,
) -> Path:
    if os.path.lexists(output):
        reject("App bundle output already exists")
    macos = output / "Contents/MacOS"
    resources = output / "Contents/Resources"
    native_host = resources / "NativeHost"
    macos.mkdir(parents=True, mode=0o755)
    native_host.mkdir(parents=True, mode=0o755)
    copy_path_nofollow(
        app_binary.parent,
        Path(app_binary.name),
        macos / app_config["executable"],
        excluded_names=set(),
        label="Release App executable",
    )
    os.chmod(macos / app_config["executable"], 0o755)
    copy_resource_tree(resource_bundle, resources / RESOURCE_BUNDLE)
    copy_path_nofollow(
        source_root,
        Path("apps/desktop/Assets") / app_config["iconFile"],
        resources / app_config["iconFile"],
        excluded_names=set(),
        label="App icon asset",
    )
    copy_path_nofollow(
        source_root,
        Path("apps/desktop/Assets") / PLATFORM_ICONS_DIRECTORY,
        resources / PLATFORM_ICONS_DIRECTORY,
        excluded_names=set(),
        label="built-in platform icon assets",
    )
    copy_path_nofollow(
        source_root,
        Path("apps/desktop/Assets") / PROVIDER_ICONS_DIRECTORY,
        resources / PROVIDER_ICONS_DIRECTORY,
        excluded_names=set(),
        label="built-in provider icon assets",
    )
    copy_path_nofollow(
        host_package.parent,
        Path(host_package.name),
        native_host / host_package.name,
        excluded_names=set(),
        label="verified Host package",
    )
    write_plist(output / "Contents/Info.plist", info_plist(app_config))
    for directory in (output, output / "Contents", macos, resources, native_host):
        os.chmod(directory, 0o755)
    return output


def release_tree_records(root: Path) -> tuple[list[dict[str, Any]], str]:
    if root.is_symlink() or not root.is_dir():
        reject("release tree root must be a real directory")
    records: list[dict[str, Any]] = []
    paths: list[Path] = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        paths.extend(Path(current) / name for name in directories + files)
    for path in sorted(paths, key=lambda item: os.fsencode(item.relative_to(root).as_posix())):
        relative = path.relative_to(root).as_posix()
        if not relative or relative.startswith("/") or any(part in {"", ".", ".."} for part in PurePosixPath(relative).parts):
            reject("release tree contains an unsafe relative path")
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            reject(f"release tree contains symlink: {relative}")
        if stat.S_ISDIR(info.st_mode):
            record = {"hash": None, "mode": mode_text(info.st_mode), "path": relative, "size": 0, "type": "directory"}
        elif stat.S_ISREG(info.st_mode):
            if info.st_nlink != 1:
                reject(f"release tree contains hardlinked file: {relative}")
            record = {
                "hash": sha256_file(path),
                "mode": mode_text(info.st_mode),
                "path": relative,
                "size": info.st_size,
                "type": "file",
            }
        else:
            reject(f"release tree contains unsupported entry: {relative}")
        records.append(record)
    digest = sha256_bytes(canonical_bytes(records))
    return records, digest


def exact_app_paths(app: Path, host_name: str, icon_file: str) -> None:
    top = {path.name for path in app.iterdir()}
    if top != {"Contents"}:
        reject("App bundle top-level tree is not exact")
    contents = {path.name for path in (app / "Contents").iterdir()}
    if contents != {"Info.plist", "MacOS", "Resources"}:
        reject("App Contents tree is not exact")
    macos = {path.name for path in (app / "Contents/MacOS").iterdir()}
    if macos != {"LinkDigestApp"}:
        reject("App MacOS tree is not exact")
    resources = {path.name for path in (app / "Contents/Resources").iterdir()}
    if resources != {RESOURCE_BUNDLE, "NativeHost", icon_file, PLATFORM_ICONS_DIRECTORY, PROVIDER_ICONS_DIRECTORY}:
        reject("App Resources tree is not exact")
    host_root = app / "Contents/Resources/NativeHost"
    if {path.name for path in host_root.iterdir()} != {host_name}:
        reject("App NativeHost tree is not exact")


def validate_plist(app: Path, config: dict[str, Any]) -> tuple[dict[str, Any], str]:
    path = app / "Contents/Info.plist"
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        reject(f"Info.plist is invalid: {error}")
    if not isinstance(value, dict) or set(value) != INFO_PLIST_KEYS or value != info_plist(config):
        reject("Info.plist does not match the frozen exact values/types")
    return value, sha256_file(path)


def verify_host_package(package: Path, source_root: Path) -> stable_host.VerifiedPackage:
    try:
        return stable_host.verify_package(package, source_root)
    except stable_host.StableHostError as error:
        reject(f"embedded Host package is invalid: {error}")


def verify_app_icon(app: Path, source_root: Path, app_config: dict[str, Any]) -> dict[str, str]:
    icon_file = app_config["iconFile"]
    embedded = app / "Contents/Resources" / icon_file
    source = source_root / "apps/desktop/Assets" / icon_file
    for path, label in ((embedded, "embedded App icon"), (source, "source App icon")):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            reject(f"{label} must be a single-link regular file")
    embedded_hash = sha256_file(embedded)
    if embedded_hash != sha256_file(source):
        reject("embedded App icon hash drifted from frozen source asset")
    icon_bytes = embedded.read_bytes()
    if (
        len(icon_bytes) < 8
        or icon_bytes[:4] != b"icns"
        or int.from_bytes(icon_bytes[4:8], byteorder="big") != len(icon_bytes)
    ):
        reject("embedded App icon is not a complete ICNS container")
    return {
        "file": icon_file,
        "hash": embedded_hash,
        "plistValue": Path(icon_file).stem,
    }


def verify_platform_icons(app: Path, source_root: Path) -> dict[str, str]:
    embedded_root = app / "Contents/Resources" / PLATFORM_ICONS_DIRECTORY
    source_root = source_root / "apps/desktop/Assets" / PLATFORM_ICONS_DIRECTORY
    if not embedded_root.exists():
        reject("embedded platform icon directory is missing")
    if embedded_root.is_symlink() or not embedded_root.is_dir():
        reject("embedded platform icon directory is unsafe")
    if not source_root.exists():
        reject("source platform icon directory is missing")
    if source_root.is_symlink() or not source_root.is_dir():
        reject("source platform icon directory is unsafe")
    if tuple(sorted(path.name for path in embedded_root.iterdir())) != PLATFORM_ICON_FILES:
        reject("embedded platform icon set drifted")
    if tuple(sorted(path.name for path in source_root.iterdir())) != PLATFORM_ICON_FILES:
        reject("source platform icon set drifted")
    hashes: dict[str, str] = {}
    for name in PLATFORM_ICON_FILES:
        embedded, source = embedded_root / name, source_root / name
        for path, label in ((embedded, "embedded platform icon"), (source, "source platform icon")):
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                reject(f"{label} must be a single-link regular file")
        digest = sha256_file(embedded)
        if digest != sha256_file(source):
            reject("embedded platform icon hash drifted from frozen source asset")
        hashes[name] = digest
    return hashes


def verify_provider_icons(app: Path, source_root: Path) -> dict[str, str]:
    embedded_root = app / "Contents/Resources" / PROVIDER_ICONS_DIRECTORY
    source_root = source_root / "apps/desktop/Assets" / PROVIDER_ICONS_DIRECTORY
    if not embedded_root.exists():
        reject("embedded provider icon directory is missing")
    if embedded_root.is_symlink() or not embedded_root.is_dir():
        reject("embedded provider icon directory is unsafe")
    if not source_root.exists():
        reject("source provider icon directory is missing")
    if source_root.is_symlink() or not source_root.is_dir():
        reject("source provider icon directory is unsafe")
    if tuple(sorted(path.name for path in embedded_root.iterdir())) != PROVIDER_ICON_FILES:
        reject("embedded provider icon set drifted")
    if tuple(sorted(path.name for path in source_root.iterdir())) != PROVIDER_ICON_FILES:
        reject("source provider icon set drifted")
    hashes: dict[str, str] = {}
    for name in PROVIDER_ICON_FILES:
        embedded, source = embedded_root / name, source_root / name
        for path, label in ((embedded, "embedded provider icon"), (source, "source provider icon")):
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                reject(f"{label} must be a single-link regular file")
        digest = sha256_file(embedded)
        if digest != sha256_file(source):
            reject("embedded provider icon hash drifted from frozen source asset")
        hashes[name] = digest
    return hashes


def verify_app(
    app: Path,
    release_unit: dict[str, Any] | None,
    source_root: Path,
    app_config: dict[str, Any],
) -> dict[str, Any]:
    host_package_name = "LinkDigestNativeHost-0.2.0-macos-arm64"
    exact_app_paths(app, host_package_name, app_config["iconFile"])
    plist, plist_hash = validate_plist(app, app_config)
    icon = verify_app_icon(app, source_root, app_config)
    platform_icons = verify_platform_icons(app, source_root)
    provider_icons = verify_provider_icons(app, source_root)
    app_executable = app / "Contents/MacOS/LinkDigestApp"
    host_package = app / "Contents/Resources/NativeHost" / host_package_name
    verified_host = verify_host_package(host_package, source_root)
    app_arch = macho_architectures(app_executable)
    app_minimum = macho_minimum_macos(app_executable)
    host_executable = host_package / verified_host.config["entrypoint"]
    host_arch = macho_architectures(host_executable)
    host_minimum = macho_minimum_macos(host_executable)
    if app_arch != app_config["architectures"] or host_arch != app_config["architectures"]:
        reject("App/Host Mach-O architecture does not match app release config")
    if app_minimum != app_config["minimumMacOS"] or host_minimum != app_config["minimumMacOS"]:
        reject("App/Host Mach-O minimum macOS does not match app release config")
    records, tree_digest = release_tree_records(app)
    signing = unsigned_signature_state(app)
    result = {
        "appExecutableHash": sha256_file(app_executable),
        "appTreeDigest": tree_digest,
        "appTreeRecords": records,
        "architectures": app_arch,
        "host": verified_host,
        "hostMinimumMacOS": host_minimum,
        "icon": icon,
        "platformIcons": platform_icons,
        "providerIcons": provider_icons,
        "minimumMacOS": app_minimum,
        "plist": plist,
        "plistHash": plist_hash,
        "schemaHash": sha256_file(app / f"Contents/Resources/{RESOURCE_BUNDLE}/Resources/contracts/capture-envelope-v1.schema.json"),
        "signing": signing,
    }
    if release_unit is not None:
        validate_release_unit(release_unit, result, app_config)
    return result


def release_unit_payload(app_result: dict[str, Any], app_config: dict[str, Any]) -> dict[str, Any]:
    host: stable_host.VerifiedPackage = app_result["host"]
    host_name = host.root.name
    return {
        "app": {
            "architectures": app_config["architectures"],
            "bundleIdentifier": app_config["bundleIdentifier"],
            "bundleIdentifierStatus": app_config["bundleIdentifierStatus"],
            "bundleVersion": app_config["bundleVersion"],
            "executable": app_config["executable"],
            "executableHash": app_result["appExecutableHash"],
            "icon": app_result["icon"],
            "platformIcons": app_result["platformIcons"],
            "providerIcons": app_result["providerIcons"],
            "minimumMacOS": app_config["minimumMacOS"],
            "plistHash": app_result["plistHash"],
            "schemaHash": app_result["schemaHash"],
            "shortVersion": app_config["shortVersion"],
            "treeDigest": app_result["appTreeDigest"],
        },
        "blockers": [
            "official-identifiers-not-frozen",
            "team-id-not-frozen",
            "developer-id-signing-not-performed",
            "notarization-not-performed",
            "stapling-not-performed",
            "real-install-browser-acceptance-not-performed",
        ],
        "formatVersion": 1,
        "host": {
            "architectures": host.metadata["architectures"],
            "embeddedPath": f"{APP_BUNDLE}/Contents/Resources/NativeHost/{host_name}",
            "entrypoint": host.metadata["entrypoint"],
            "minimumMacOS": host.metadata["minimumMacOS"],
            "name": host_name,
            "packageDigest": host.package_digest,
            "version": host.metadata["productVersion"],
        },
        "productStatus": "BLOCKED",
        "separateAuthorizationRequired": True,
        "signing": {"mode": "unsigned", "teamID": None},
        "unitID": UNIT_ID,
    }


def require_exact_dict(value: object, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        reject(f"{label} keys do not match the strict format")
    return value


def validate_release_unit(value: dict[str, Any], app_result: dict[str, Any], config: dict[str, Any]) -> None:
    require_exact_dict(value, RELEASE_UNIT_KEYS, "release-unit")
    expected = release_unit_payload(app_result, config)
    if value != expected:
        reject("release-unit does not bind exactly to the App/Host/config evidence")


def validate_staging(staging: Path, source_root: Path, config: dict[str, Any]) -> dict[str, Any]:
    if staging.is_symlink() or not staging.is_dir():
        reject("DMG staging root is unsafe")
    names = {path.name for path in staging.iterdir()}
    if names != {APP_BUNDLE, RELEASE_UNIT_NAME}:
        reject("DMG staging root must contain exactly LinkDigest.app and release-unit.json")
    unit_path = staging / RELEASE_UNIT_NAME
    info = unit_path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o644:
        reject("release-unit.json must be a single-link 0644 regular file")
    unit = load_json(unit_path, "release-unit")
    if canonical_bytes(unit) != unit_path.read_bytes():
        reject("release-unit.json is not canonical JSON")
    result = verify_app(staging / APP_BUNDLE, unit, source_root, config)
    return {"releaseUnit": unit, "appResult": result}


def parse_attach_plist(payload: bytes, expected_mount: Path) -> str:
    try:
        value = plistlib.loads(payload)
    except plistlib.InvalidFileException:
        reject("hdiutil attach returned invalid plist", CLEANUP_REQUIRED)
    entities = value.get("system-entities") if isinstance(value, dict) else None
    if not isinstance(entities, list):
        reject("hdiutil attach plist lacks system-entities", CLEANUP_REQUIRED)
    matches = []
    for entry in entities:
        if isinstance(entry, dict) and entry.get("mount-point") == str(expected_mount) and isinstance(entry.get("dev-entry"), str):
            matches.append(entry["dev-entry"])
    if len(matches) != 1 or not matches[0].startswith("/dev/"):
        reject("hdiutil attach did not provide one exact dev-entry/mount-point", CLEANUP_REQUIRED)
    return matches[0]


def exact_image_devices(info_payload: bytes, dmg: Path, mount: Path) -> list[str]:
    try:
        value = plistlib.loads(info_payload)
    except plistlib.InvalidFileException:
        return []
    images = value.get("images") if isinstance(value, dict) else None
    if not isinstance(images, list):
        return []
    matches: list[str] = []
    for image in images:
        if not isinstance(image, dict) or image.get("image-path") != str(dmg):
            continue
        entities = image.get("system-entities")
        if not isinstance(entities, list):
            continue
        for entry in entities:
            if (
                isinstance(entry, dict)
                and entry.get("mount-point") == str(mount)
                and isinstance(entry.get("dev-entry"), str)
                and entry["dev-entry"].startswith("/dev/")
            ):
                matches.append(entry["dev-entry"])
    return sorted(set(matches), key=os.fsencode)


def discover_exact_attached_device(dmg: Path, mount: Path) -> str:
    info = run_command([HDITUTIL, "info", "-plist"], allowed={HDITUTIL})
    if info.returncode != 0:
        reject("cannot inspect hdiutil state after attach", CLEANUP_REQUIRED)
    matches = exact_image_devices(info.stdout, dmg, mount)
    if len(matches) != 1:
        reject("attach state cannot be bound to one exact DMG/mount device", CLEANUP_REQUIRED)
    return matches[0]


def image_is_exactly_mounted(info_payload: bytes, dmg: Path, mount: Path, dev: str) -> bool:
    return exact_image_devices(info_payload, dmg, mount) == [dev]


def no_residual_mount(dmg: Path, mount: Path) -> bool:
    info = run_command([HDITUTIL, "info", "-plist"], allowed={HDITUTIL})
    if info.returncode != 0:
        return False
    try:
        value = plistlib.loads(info.stdout)
    except plistlib.InvalidFileException:
        return False
    images = value.get("images") if isinstance(value, dict) else None
    if not isinstance(images, list):
        return False
    for image in images:
        if not isinstance(image, dict):
            continue
        if image.get("image-path") == str(dmg):
            return False
        for entry in image.get("system-entities", []):
            if isinstance(entry, dict) and entry.get("mount-point") == str(mount):
                return False
    return True


def detach_exact(dmg: Path, mount: Path, dev: str) -> None:
    ordinary = run_command([HDITUTIL, "detach", dev], allowed={HDITUTIL})
    if ordinary.returncode == 0:
        if not no_residual_mount(dmg, mount):
            reject("DMG detach reported success but a residual mount remains", CLEANUP_REQUIRED)
        return
    verified = run_command([HDITUTIL, "verify", str(dmg)], allowed={HDITUTIL})
    info = run_command([HDITUTIL, "info", "-plist"], allowed={HDITUTIL})
    if verified.returncode != 0 or info.returncode != 0 or not image_is_exactly_mounted(info.stdout, dmg, mount, dev):
        reject("ordinary detach failed and exact mounted image could not be reconfirmed", CLEANUP_REQUIRED)
    forced = run_command([HDITUTIL, "detach", "-force", dev], allowed={HDITUTIL})
    if forced.returncode != 0 or not no_residual_mount(dmg, mount):
        reject("forced exact detach failed; audit scene is preserved", CLEANUP_REQUIRED)


def guarded_attach_operation(
    attach: subprocess.CompletedProcess[bytes],
    dmg: Path,
    mount: Path,
    operation: Callable[[str], Any],
) -> Any:
    """Bind every attach return to a cleanup guard before trusting output."""
    reported_dev: str | None = None
    attach_error: ReleaseUnitError | None = None
    if attach.returncode == 0:
        try:
            reported_dev = parse_attach_plist(attach.stdout, mount)
        except ReleaseUnitError as error:
            attach_error = error
    else:
        detail = (attach.stderr + attach.stdout).decode("utf-8", errors="replace")[-2000:]
        attach_error = ReleaseUnitError(ENVIRONMENT_BLOCKED, f"hdiutil attach failed: {detail}")
    # Even a syntactically valid success plist is only a report. Bind cleanup
    # to the current system state for this exact DMG + mount before operating.
    dev = discover_exact_attached_device(dmg, mount)
    if reported_dev is not None and reported_dev != dev:
        attach_error = ReleaseUnitError(
            CLEANUP_REQUIRED,
            "attach plist device does not match exact current DMG/mount state",
        )
    try:
        if attach_error is not None:
            raise attach_error
        return operation(dev)
    finally:
        detach_exact(dmg, mount, dev)


def create_and_verify_dmg(staging: Path, output: Path, audit_root: Path, source_root: Path, config: dict[str, Any]) -> dict[str, Any]:
    if os.path.lexists(output):
        reject("DMG output must not already exist")
    command_ok(
        [
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
        ],
        allowed={HDITUTIL},
    )
    command_ok([HDITUTIL, "verify", str(output)], allowed={HDITUTIL})
    mount = audit_root / "mount"
    mount.mkdir(mode=0o700)
    attach = run_command(
        [
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
        ],
        allowed={HDITUTIL},
    )
    # Cleanup responsibility starts immediately after every attach return,
    # including nonzero/partial attach and malformed or ambiguous plist output.
    verified = guarded_attach_operation(
        attach,
        output,
        mount,
        lambda _dev: validate_staging(mount, source_root, config),
    )
    if verified is None:
        reject("mounted DMG verification produced no evidence", INTERNAL_ERROR)
    return {
        "dmgHash": sha256_file(output),
        "mountedAppTreeDigest": verified["appResult"]["appTreeDigest"],
        "residualMount": False,
    }


TARGET_PROBE_TOKENS = (
    "native-host-root",
    "receipt-v1",
    "receipt-v2",
    "chrome-default-manifest",
    "brave-default-manifest",
    "edge-default-manifest",
)


def fixed_target_paths() -> list[tuple[str, Path, str]]:
    try:
        home = Path(pwd.getpwuid(os.geteuid()).pw_dir)
    except (KeyError, OSError) as error:
        reject(f"effective-user home is unavailable: {error}", BLOCKED)
    if not home.is_absolute():
        reject("effective-user home is not absolute", BLOCKED)
    host_root = home / "Library/Application Support/LinkDigest/NativeMessagingHost"
    host_name = "com.syc.linkdigest.v01.json"
    targets = [
        ("native-host-root", host_root, "directory"),
        ("receipt-v1", host_root / "receipt-v1.json", "receipt-v1"),
        ("receipt-v2", host_root / "receipt-v2.json", "receipt-v2"),
        (
            "chrome-default-manifest",
            home / "Library/Application Support/Google/Chrome/NativeMessagingHosts" / host_name,
            "manifest",
        ),
        (
            "brave-default-manifest",
            home / "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts" / host_name,
            "manifest",
        ),
        (
            "edge-default-manifest",
            home / "Library/Application Support/Microsoft Edge/NativeMessagingHosts" / host_name,
            "manifest",
        ),
    ]
    if tuple(token for token, _, _ in targets) != TARGET_PROBE_TOKENS:
        reject("real target probe token contract drifted", INTERNAL_ERROR)
    return targets


def target_snapshot(info: os.stat_result) -> tuple[int, ...]:
    """Stable leaf metadata excluding atime; generated from one open fd."""
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_nlink,
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def open_target_leaf(
    path: Path,
    kind: str,
) -> tuple[str, int | None, int | None, os.stat_result | None, str | None, str | None]:
    """Anchor every component and the leaf with openat + O_NOFOLLOW."""
    try:
        validate_lexical_absolute(str(path), "target leaf")
    except ReleaseUnitError:
        return "unknown", None, None, None, None, "unsafe-path"
    descriptor = os.open("/", os.O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try:
        for component in path.parts[1:-1]:
            try:
                next_descriptor = os.open(
                    component,
                    os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                    dir_fd=descriptor,
                )
            except FileNotFoundError:
                os.close(descriptor)
                return "absent", None, None, None, None, "missing"
            except OSError as error:
                os.close(descriptor)
                reason = "symlink-component" if error.errno == errno.ELOOP else "unsafe-parent-component"
                return "unknown", None, None, None, None, reason
            os.close(descriptor)
            descriptor = next_descriptor
        leaf_name = path.name
        flags = os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        if kind == "directory":
            flags |= O_DIRECTORY
        try:
            leaf_fd = os.open(leaf_name, flags, dir_fd=descriptor)
        except FileNotFoundError:
            os.close(descriptor)
            return "absent", None, None, None, None, "missing"
        except OSError as error:
            reason = "symlink-component" if error.errno == errno.ELOOP else "unsafe-leaf-type"
            os.close(descriptor)
            return "unknown", None, None, None, None, reason
        return "present", descriptor, leaf_fd, os.fstat(leaf_fd), leaf_name, None
    except BaseException:
        os.close(descriptor)
        raise


def read_fd_bounded(descriptor: int, limit: int) -> tuple[bytes, bool]:
    os.lseek(descriptor, 0, os.SEEK_SET)
    payload = bytearray()
    while len(payload) <= limit:
        chunk = os.read(descriptor, min(64 * 1024, limit + 1 - len(payload)))
        if not chunk:
            break
        payload.extend(chunk)
    return bytes(payload), len(payload) > limit


def canonical_json_payload(payload: bytes) -> tuple[dict[str, Any] | None, str | None]:
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None, "invalid-json"
    if not isinstance(value, dict) or canonical_bytes(value) != payload:
        return None, "noncanonical-json"
    return value, None


def validate_probe_receipt(value: dict[str, Any], kind: str) -> bool:
    if kind == "receipt-v1":
        keys = {"formatVersion", "hostName", "installedVersion", "packageDigest", "versionDirectory", "ownedManifests"}
        if set(value) != keys or type(value["formatVersion"]) is not int or value["formatVersion"] != 1:
            return False
        if value["hostName"] != "com.syc.linkdigest.v01" or not isinstance(value["installedVersion"], str):
            return False
        if not isinstance(value["packageDigest"], str) or not SHA256_RE.fullmatch(value["packageDigest"]):
            return False
        if not isinstance(value["versionDirectory"], str) or not value["versionDirectory"].startswith("/"):
            return False
        manifests = value["ownedManifests"]
        return isinstance(manifests, list) and bool(manifests) and all(
            isinstance(item, dict)
            and set(item) == {"path", "sha256"}
            and isinstance(item["path"], str)
            and item["path"].startswith("/")
            and isinstance(item["sha256"], str)
            and SHA256_RE.fullmatch(item["sha256"])
            for item in manifests
        )
    keys = {"current", "formatVersion", "hostName", "lineage", "ownedManifests"}
    if set(value) != keys or type(value["formatVersion"]) is not int or value["formatVersion"] != 2:
        return False
    if value["hostName"] != "com.syc.linkdigest.v01" or not isinstance(value["current"], dict):
        return False
    if not isinstance(value["lineage"], list) or not isinstance(value["ownedManifests"], list):
        return False
    tree_keys = {"directories", "files", "packageDigest", "path", "version"}
    records = value["lineage"] + [value["current"]]
    if not all(isinstance(item, dict) and set(item) == tree_keys for item in records):
        return False
    return all(
        isinstance(item, dict)
        and set(item) == {"hash", "mode", "path", "role"}
        and isinstance(item["hash"], str)
        and SHA256_RE.fullmatch(item["hash"])
        and item["mode"] == "0600"
        for item in value["ownedManifests"]
    )


def validate_probe_manifest(value: dict[str, Any]) -> bool:
    if set(value) != {"allowed_origins", "description", "name", "path", "type"}:
        return False
    origins = value["allowed_origins"]
    if not isinstance(origins, list) or not origins or origins != byte_sorted(set(origins)):
        return False
    if not all(
        isinstance(origin, str)
        and origin.startswith("chrome-extension://")
        and origin.endswith("/")
        and EXTENSION_ID_RE.fullmatch(origin[len("chrome-extension://") : -1])
        for origin in origins
    ):
        return False
    return (
        value["name"] == "com.syc.linkdigest.v01"
        and value["type"] == "stdio"
        and isinstance(value["description"], str)
        and isinstance(value["path"], str)
        and value["path"].startswith("/")
    )


def probe_one_internal(
    token: str,
    path: Path,
    kind: str,
    *,
    after_open: Callable[[Path], None] | None = None,
) -> tuple[dict[str, Any], bool]:
    presence, parent_fd, leaf_fd, info, leaf_name, reason = open_target_leaf(path, kind)
    result: dict[str, Any] = {
        "token": token,
        "state": "absent" if presence == "absent" else "unknown",
        "reason": reason or ("missing" if presence == "absent" else "unsafe-type"),
        "contentHash": None,
        "mode": None,
        "nlink": None,
        "owned": False,
    }
    if presence != "present" or info is None or parent_fd is None or leaf_fd is None or leaf_name is None:
        return result, True
    before = target_snapshot(info)
    unchanged = True
    try:
        result.update({"mode": mode_text(info.st_mode), "nlink": info.st_nlink, "owned": info.st_uid == os.geteuid()})
        if after_open is not None:
            after_open(path)
        if info.st_uid != os.geteuid():
            result["reason"] = "not-current-user-owned"
        elif kind == "directory":
            if stat.S_ISDIR(info.st_mode) and info.st_nlink >= 1:
                result.update({"state": "owned", "reason": "owned-directory"})
        elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            result["reason"] = "not-single-link-regular-file"
        else:
            limit = 1024 * 1024 if kind.startswith("receipt") else 256 * 1024
            payload, oversized = read_fd_bounded(leaf_fd, limit)
            if oversized:
                result.update({"state": "malformed", "reason": "size-limit", "contentHash": None})
            else:
                result["contentHash"] = sha256_bytes(payload)
                value, error = canonical_json_payload(payload)
                if error is not None or value is None:
                    result.update({"state": "malformed", "reason": error or "invalid-json"})
                else:
                    valid = validate_probe_receipt(value, kind) if kind.startswith("receipt") else validate_probe_manifest(value)
                    result.update(
                        {
                            "state": "owned" if valid else "malformed",
                            "reason": "strict-json-valid" if valid else "strict-schema-invalid",
                        }
                    )
        after = os.fstat(leaf_fd)
        try:
            path_info = os.stat(leaf_name, dir_fd=parent_fd, follow_symlinks=False)
        except OSError:
            unchanged = False
        else:
            unchanged = target_snapshot(after) == before and (
                path_info.st_dev,
                path_info.st_ino,
                stat.S_IFMT(path_info.st_mode),
            ) == (
                info.st_dev,
                info.st_ino,
                stat.S_IFMT(info.st_mode),
            )
        if not unchanged:
            result.update({"state": "unknown", "reason": "leaf-changed-during-probe", "contentHash": None})
        return result, unchanged
    finally:
        os.close(leaf_fd)
        os.close(parent_fd)


def probe_one(
    token: str,
    path: Path,
    kind: str,
    *,
    after_open: Callable[[Path], None] | None = None,
) -> dict[str, Any]:
    return probe_one_internal(token, path, kind, after_open=after_open)[0]


def probe_targets() -> dict[str, Any]:
    targets = fixed_target_paths()
    inspected = [probe_one_internal(token, path, kind) for token, path, kind in targets]
    results = [item[0] for item in inspected]
    if not all(item[1] for item in inspected):
        reject("real target leaf snapshot changed during read-only probe", CLEANUP_REQUIRED)
    states = {item["state"] for item in results}
    status = "BLOCKED" if states & {"unknown", "malformed"} else "PROBED"
    return {"status": status, "targets": results, "unchanged": True}


def build_release_unit(audit_root_text: str, *, prepare_only: bool = False) -> dict[str, Any]:
    root = repository_root()
    audit_root = validate_new_audit_root(audit_root_text)
    workspace_before = inventory_tree(root, include_metadata=True)
    audit_root.mkdir(mode=0o700)
    (audit_root / ".workspace-inventory-before").write_text(workspace_before + "\n", encoding="ascii")
    os.chmod(audit_root / ".workspace-inventory-before", 0o600)
    source = audit_root / "source"
    dependencies = audit_root / "dependencies/GRDB.swift"
    output = audit_root / "output"
    staging = audit_root / "staging"
    output.mkdir(mode=0o700)
    staging.mkdir(mode=0o755)
    try:
        app_config = load_app_config(root)
        copy_source(root, source)
        copy_grdb(root, dependencies)
        patch_local_dependency(source, dependencies)
        sync_contracts(source)
        app_binary, host_binary, resource_bundle = build_swift_products(source, audit_root)

        host_package_name = "LinkDigestNativeHost-0.2.0-macos-arm64"
        host_package = audit_root / "host-package" / host_package_name
        host_package.parent.mkdir(mode=0o755)
        try:
            stable_host.create_package(host_binary, resource_bundle, host_package, source)
        except stable_host.StableHostError as error:
            reject(f"Host package creation failed: {error}")
        verify_host_package(host_package, source)

        app = build_app_bundle(staging / APP_BUNDLE, app_binary, resource_bundle, host_package, app_config, source)
        initial = verify_app(app, None, source, app_config)
        unit = release_unit_payload(initial, app_config)
        unit_path = staging / RELEASE_UNIT_NAME
        unit_path.write_bytes(canonical_bytes(unit))
        os.chmod(unit_path, 0o644)
        staging_result = validate_staging(staging, source, app_config)
        dmg = output / DMG_NAME
        prepared = {
            "dmg": str(dmg),
            "releaseUnitHash": sha256_file(unit_path),
            "stagingAppTreeDigest": staging_result["appResult"]["appTreeDigest"],
            "stagingInventory": inventory_tree(staging, include_metadata=False),
            "workspaceInventoryBefore": workspace_before,
        }
        prepared_path = audit_root / "prepared.json"
        prepared_path.write_bytes(canonical_bytes(prepared))
        os.chmod(prepared_path, 0o600)
        if prepare_only:
            workspace_after_prepare = inventory_tree(root, include_metadata=True)
            if workspace_after_prepare != workspace_before:
                reject("workspace content or metadata changed during audit preparation", CLEANUP_REQUIRED)
            return {
                "auditRoot": str(audit_root),
                "dmg": str(dmg),
                "engineeringStatus": "prepared",
                "productStatus": "BLOCKED",
                "separateAuthorizationRequired": True,
                "workspaceInventoryUnchanged": True,
            }
        dmg_result = create_and_verify_dmg(staging, dmg, audit_root, source, app_config)
        target_probe = probe_targets()
        workspace_after = inventory_tree(root, include_metadata=True)
        if workspace_after != workspace_before:
            reject("workspace content or metadata changed during audit build", CLEANUP_REQUIRED)
        report = {
            "auditRoot": str(audit_root),
            "dmg": str(dmg),
            "dmgHash": dmg_result["dmgHash"],
            "engineeringStatus": "candidate",
            "productStatus": "BLOCKED",
            "releaseUnitHash": sha256_file(unit_path),
            "residualMounts": False,
            "separateAuthorizationRequired": True,
            "targetProbe": target_probe,
            "unitID": UNIT_ID,
            "workspaceInventoryUnchanged": True,
        }
        report_path = audit_root / "r4a-engineering-report.json"
        report_path.write_bytes(canonical_bytes(report))
        os.chmod(report_path, 0o600)
        # The report itself is deliberately outside staging/DMG and is not part
        # of the signed-or-notarized product truth.
        return report
    except BaseException:
        # Preserve the named audit root and all evidence for deterministic
        # recovery.  No automatic cleanup is allowed in r4a.
        raise


def verify_mounted_audit(audit_root_text: str, mount_point_text: str, dev_entry: str) -> dict[str, Any]:
    audit = validate_existing_audit_root(audit_root_text)
    mount = validate_lexical_absolute(mount_point_text, "--mount-point")
    if mount != audit / "mount" or not dev_entry.startswith("/dev/") or "/" in dev_entry[len("/dev/") :]:
        reject("mounted verification requires the exact audit mount and one dev-entry")
    dmg = audit / "output" / DMG_NAME
    if not dmg.is_file() or dmg.is_symlink():
        reject("prepared DMG is missing")
    command_ok([HDITUTIL, "verify", str(dmg)], allowed={HDITUTIL})
    info = command_ok([HDITUTIL, "info", "-plist"], allowed={HDITUTIL})
    if not image_is_exactly_mounted(info.stdout, dmg, mount, dev_entry):
        reject("mounted audit does not match the exact DMG/mount/dev-entry")
    source = audit / "source"
    config = load_app_config(source)
    staging = validate_staging(audit / "staging", source, config)
    mounted = validate_staging(mount, source, config)
    staging_unit_hash = sha256_file(audit / "staging" / RELEASE_UNIT_NAME)
    mounted_unit_hash = sha256_file(mount / RELEASE_UNIT_NAME)
    if mounted_unit_hash != staging_unit_hash:
        reject("mounted release-unit differs from staging")
    if mounted["appResult"]["appTreeDigest"] != staging["appResult"]["appTreeDigest"]:
        reject("mounted App tree differs from staging")
    evidence = {
        "devEntry": dev_entry,
        "dmgHash": sha256_file(dmg),
        "mountPoint": str(mount),
        "mountedAppTreeDigest": mounted["appResult"]["appTreeDigest"],
        "releaseUnitHash": mounted_unit_hash,
        "verifiedReadOnly": True,
    }
    path = audit / "mounted-verification.json"
    path.write_bytes(canonical_bytes(evidence))
    os.chmod(path, 0o600)
    return evidence


def finalize_verified_audit(audit_root_text: str) -> dict[str, Any]:
    audit = validate_existing_audit_root(audit_root_text)
    root = repository_root()
    source = audit / "source"
    config = load_app_config(source)
    prepared = load_json(audit / "prepared.json", "prepared evidence")
    evidence = load_json(audit / "mounted-verification.json", "mounted verification evidence")
    dmg = audit / "output" / DMG_NAME
    if prepared.get("dmg") != str(dmg) or evidence.get("verifiedReadOnly") is not True:
        reject("prepared/mounted evidence identity is invalid")
    if not dmg.is_file() or dmg.is_symlink() or sha256_file(dmg) != evidence.get("dmgHash"):
        reject("DMG differs from mounted verification evidence")
    command_ok([HDITUTIL, "verify", str(dmg)], allowed={HDITUTIL})
    mount = audit / "mount"
    if not no_residual_mount(dmg, mount):
        reject("residual DMG mount remains", CLEANUP_REQUIRED)
    staging = validate_staging(audit / "staging", source, config)
    if staging["appResult"]["appTreeDigest"] != evidence.get("mountedAppTreeDigest"):
        reject("staging App tree differs from mounted verification evidence")
    unit_hash = sha256_file(audit / "staging" / RELEASE_UNIT_NAME)
    if unit_hash != prepared.get("releaseUnitHash") or unit_hash != evidence.get("releaseUnitHash"):
        reject("release-unit hash differs across prepared/mounted/final evidence")
    target_probe = probe_targets()
    workspace_before_path = audit / ".workspace-inventory-before"
    try:
        workspace_before = workspace_before_path.read_text(encoding="ascii").strip()
    except OSError:
        reject("workspace inventory baseline is missing")
    workspace_after = inventory_tree(root, include_metadata=True)
    if workspace_after != workspace_before:
        reject("workspace content or metadata changed during audit build", CLEANUP_REQUIRED)
    report = {
        "auditRoot": str(audit),
        "dmg": str(dmg),
        "dmgHash": evidence["dmgHash"],
        "engineeringStatus": "candidate",
        "productStatus": "BLOCKED",
        "releaseUnitHash": unit_hash,
        "residualMounts": False,
        "separateAuthorizationRequired": True,
        "targetProbe": target_probe,
        "unitID": UNIT_ID,
        "workspaceInventoryUnchanged": True,
    }
    report_path = audit / "r4a-engineering-report.json"
    report_path.write_bytes(canonical_bytes(report))
    os.chmod(report_path, 0o600)
    return report


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build")
    build.add_argument("--audit-root", required=True)
    build.add_argument("--prepare-only", action="store_true")
    mounted = subparsers.add_parser("verify-mounted")
    mounted.add_argument("--audit-root", required=True)
    mounted.add_argument("--mount-point", required=True)
    mounted.add_argument("--dev-entry", required=True)
    finalize = subparsers.add_parser("finalize-existing")
    finalize.add_argument("--audit-root", required=True)
    subparsers.add_parser("probe-targets")
    check_config = subparsers.add_parser("check-config")
    check_config.add_argument("--root")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_arguments(argv or sys.argv[1:])
    try:
        if args.command == "build":
            print(canonical_bytes(build_release_unit(args.audit_root, prepare_only=args.prepare_only)).decode("utf-8"), end="")
            return SUCCESS
        if args.command == "verify-mounted":
            print(canonical_bytes(verify_mounted_audit(args.audit_root, args.mount_point, args.dev_entry)).decode("utf-8"), end="")
            return SUCCESS
        if args.command == "finalize-existing":
            report = finalize_verified_audit(args.audit_root)
            print(canonical_bytes(report).decode("utf-8"), end="")
            return BLOCKED if report["targetProbe"]["status"] == "BLOCKED" else SUCCESS
        if args.command == "probe-targets":
            report = probe_targets()
            print(canonical_bytes(report).decode("utf-8"), end="")
            return BLOCKED if report["status"] == "BLOCKED" else SUCCESS
        root = Path(args.root) if args.root else repository_root()
        load_app_config(root)
        print("app release config: OK")
        return SUCCESS
    except ReleaseUnitError as error:
        print(f"release-unit: {error}", file=sys.stderr)
        return error.code
    except stable_host.StableHostError as error:
        print(f"release-unit: {error}", file=sys.stderr)
        return INVALID_UNSAFE
    except BaseException as error:
        print(f"release-unit: internal error: {error}", file=sys.stderr)
        return INTERNAL_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
