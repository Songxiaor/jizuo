#!/usr/bin/env python3
"""Build and verify the unsigned LinkDigest r4a App + DMG release unit.

The production build is deliberately confined to a caller-created name under
canonical /private/tmp.  The path itself must not exist yet.  Source, the
resolved GRDB checkout, and the checksum-verified Sparkle artifact are copied
read-only into that audit root; no
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
import zipfile
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
# `.app` 的文件名。Dock 和 Finder 显示的就是它——CFBundleDisplayName 管的是
# 菜单栏,管不到这里,所以产品名要在 Dock 里可见就必须改这一处。
#
# 代价写在这里免得下次又被当成"随便改改":native host manifest 里存的是
# 指向 bundle 内部的**绝对路径**,改名会让已装的扩展立刻找不到 Host
# (表现为 NATIVE_HOST_NOT_FOUND)。改名后每台机器都要重装一次浏览器支持。
APP_NAME = "汲作"
APP_BUNDLE = f"{APP_NAME}.app"
RESOURCE_BUNDLE = "LinkDigest_LinkDigestCore.bundle"
APP_ICON_FILE = "AppIcon.icns"
PLATFORM_ICONS_DIRECTORY = "PlatformIcons"
PLATFORM_ICON_FILES = ("bilibili.svg", "douban.svg", "douyin.svg", "github.svg", "juejin.svg", "medium.svg", "reddit.svg", "toutiao.svg", "wechat.svg", "weibo.svg", "x.com.svg", "xiaohongshu.svg", "youtube.svg", "zhihu.svg")
PROVIDER_ICONS_DIRECTORY = "ProviderIcons"
PROVIDER_ICON_FILES = ("bailian.svg", "deepinfra.svg", "deepseek.svg", "groq.svg", "ollama.svg", "openai.svg", "opencode.svg", "openrouter.svg", "siliconflow.svg", "stepfun.svg", "zhipu.svg")
BROWSER_EXTENSION_DIRECTORY = "BrowserExtension"
SPARKLE_VERSION = "2.9.5"
SPARKLE_FRAMEWORK = "Sparkle.framework"
SPARKLE_ARTIFACT_RELATIVE = Path("apps/desktop/.build/artifacts/sparkle/Sparkle")
SPARKLE_LICENSE_SHA256 = "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe"
THIRD_PARTY_LICENSES_DIRECTORY = "ThirdPartyLicenses"
THIRD_PARTY_LICENSE_HASHES = {
    "GRDB-LICENSE.txt": "9853f9dce81365fcc1d9b46004633354450164b8d17904e92e80c444545f7e87",
    "Sparkle-LICENSE.txt": SPARKLE_LICENSE_SHA256,
}
SPARKLE_FRAMEWORK_SYMLINKS = {
    "Autoupdate": "Versions/Current/Autoupdate",
    "Headers": "Versions/Current/Headers",
    "Modules": "Versions/Current/Modules",
    "PrivateHeaders": "Versions/Current/PrivateHeaders",
    "Resources": "Versions/Current/Resources",
    "Sparkle": "Versions/Current/Sparkle",
    "Updater.app": "Versions/Current/Updater.app",
    "Versions/Current": "B",
    "XPCServices": "Versions/Current/XPCServices",
}
BROWSER_EXTENSION_IDENTITY = Path("config/extension-identity.json")
PRODUCT_DISPLAY = Path("apps/desktop/Sources/LinkDigestCore/Resources/product-display.json")
RELEASE_UNIT_NAME = "release-unit.json"
UNIT_ID = "com.syc.linkdigest.release-unit.v1"
DMG_NAME = "汲作-0.2.17-macOS-Universal.dmg"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SEMVER_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*)){0,2}$")
EXTENSION_ID_RE = re.compile(r"^[a-p]{32}$")
SPARKLE_ED_KEY_RE = re.compile(r"^[A-Za-z0-9+/]{43}=$")

SWIFT = "/usr/bin/swift"
HDITUTIL = "/usr/bin/hdiutil"
LIPO = "/usr/bin/lipo"
OTOOL = "/usr/bin/otool"
CODESIGN = "/usr/bin/codesign"
INSTALL_NAME_TOOL = "/usr/bin/install_name_tool"
GIT = "/usr/bin/git"
XCODE_DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")

SPARKLE_RUNTIME_RPATH = "@executable_path/../Frameworks"
SPARKLE_INSTALL_NAME = "@rpath/Sparkle.framework/Versions/B/Sparkle"

APP_CONFIG_KEYS = {
    "formatVersion",
    "appName",
    # 界面上显示的名字。和 appName 分开是因为 appName 同时是 `.app` 的**文件名**,
    # 而 native host manifest 里写死了那条绝对路径——改文件名会让已装的扩展
    # 立刻找不到 Host。产品改名(包括以后换英文名)只动这一个字段。
    "appDisplayName",
    "iconFile",
    "executable",
    "bundleIdentifier",
    "bundleIdentifierStatus",
    "shortVersion",
    "bundleVersion",
    "minimumMacOS",
    "architectures",
    "category",
    "sparkleAutomaticallyUpdates",
    "sparkleFeedURL",
    "sparklePublicEDKey",
}

INFO_PLIST_KEYS = {
    "CFBundleDevelopmentRegion",
    "CFBundleLocalizations",
    "CFBundleDisplayName",
    "CFBundleExecutable",
    "CFBundleIconFile",
    "CFBundleIdentifier",
    "CFBundleInfoDictionaryVersion",
    "CFBundleName",
    "CFBundlePackageType",
    "CFBundleShortVersionString",
    "CFBundleURLTypes",
    "CFBundleVersion",
    "LSApplicationCategoryType",
    "LSMinimumSystemVersion",
    "NSHighResolutionCapable",
    "SUAutomaticallyUpdate",
    "SUFeedURL",
    "SUPublicEDKey",
}

# `linkdigest://digest/<taskID>` 的注册。导到知识库的那份 Markdown 靠它跳回
# App 定位到具体条目——没有它,检索命中之后就回不来了。
#
# 这个键和下面 `info_plist()` 里的取值必须一起改:`validate_plist` 做的是
# 精确比对(键集合与取值都要一致),漏掉任何一处都会让整个发布单元被 reject。
URL_SCHEME = "linkdigest"

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
    # 冻结清单：config 里这些值必须和这里登记的一字不差。
    #
    # 「那不是把同一个值写了两遍吗」——是，而且是故意的。这份清单是闸门，
    # config 是被它检查的输入。改名、改版本号要动两处，正是这道闸门的全部用途：
    # 单改 config 改不动产物，只有在代码里也登记一次才算数。
    # 反过来让它从 config 读，校验就退化成拿 config 跟自己比，等于没有。
    #
    # 所以别的脚本要拼 `.app` 文件名时用 `APP_BUNDLE`，不要读 config 的 appName——
    # 值相同，但方向反了。
    exact_strings = {
        "appName": APP_NAME,
        "iconFile": APP_ICON_FILE,
        "executable": "LinkDigestApp",
        "bundleIdentifier": "com.syc.linkdigest",
        "bundleIdentifierStatus": "engineering-candidate",
        "shortVersion": "0.2.17",
        "bundleVersion": "26",
        "minimumMacOS": "15.0",
        "category": "public.app-category.productivity",
        "sparkleFeedURL": "https://github.com/Songxiaor/jizuo/releases/latest/download/appcast.xml",
        "sparklePublicEDKey": "s0iZUen0dQ8irIs2kGI4ulzWvrqOn18atSGPguAIWHY=",
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
    if type(config["architectures"]) is not list or config["architectures"] != stable_host.SUPPORTED_ARCHITECTURES:
        reject(f"architectures must be exactly {stable_host.SUPPORTED_ARCHITECTURES}")
    if type(config["sparkleAutomaticallyUpdates"]) is not bool or config["sparkleAutomaticallyUpdates"]:
        reject("sparkleAutomaticallyUpdates must be false for the bootstrap release")
    if not SPARKLE_ED_KEY_RE.fullmatch(config["sparklePublicEDKey"]):
        reject("sparklePublicEDKey must be one canonical Ed25519 public key")
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


GIT_REGULAR_MODES = {0o100644, 0o100755}
R4A_SOURCE_PATHS = (
    "apps/desktop",
    "apps/browser-extension",
    "contracts",
    "config",
    "licenses",
    "scripts/sync-contracts.sh",
    "scripts/native-host/stable_host.py",
)


def parse_git_tracked_entries(payload: bytes) -> list[tuple[int, str]]:
    """Strictly parse NUL-delimited ``git ls-files --stage`` output."""
    if payload and not payload.endswith(b"\0"):
        reject("git ls-files output is not NUL terminated", INTERNAL_ERROR)
    records = payload[:-1].split(b"\0") if payload else []
    entries: list[tuple[int, str]] = []
    seen: set[str] = set()
    pattern = re.compile(rb"([0-7]{6}) ([0-9a-f]{40}|[0-9a-f]{64}) ([0-3])\t(.+)", re.DOTALL)
    for record in records:
        match = pattern.fullmatch(record)
        if match is None:
            reject("git ls-files produced malformed staged output", INTERNAL_ERROR)
        mode_text_raw, object_id, stage_raw, path_raw = match.groups()
        if stage_raw != b"0":
            reject("git index contains a non-stage-0 entry")
        if not object_id.strip(b"0"):
            reject("git index contains an intent-to-add or null object entry")
        try:
            path = path_raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            reject("git index path is not valid UTF-8")
        parts = path.split("/")
        if path.startswith("/") or not path or any(part in {"", ".", ".."} for part in parts):
            reject(f"git index contains an unsafe path: {path!r}")
        if path in seen:
            reject(f"git index contains a duplicate path: {path}")
        seen.add(path)
        mode = int(mode_text_raw, 8)
        if mode == 0o120000:
            reject(f"tracked symlink is not permitted: {path}")
        if mode == 0o160000:
            reject(f"tracked submodule is not permitted: {path}")
        if mode not in GIT_REGULAR_MODES:
            reject(f"tracked entry is not a regular file: {path}")
        entries.append((mode, path))
    return sorted(entries, key=lambda item: os.fsencode(item[1]))


def git_tracked_entries(root: Path) -> list[tuple[int, str]]:
    """Read the live repository index exactly once and return tracked files."""
    try:
        root_before = root.lstat()
    except OSError as error:
        reject(f"repository root is unavailable: {error}", ENVIRONMENT_BLOCKED)
    if not stat.S_ISDIR(root_before.st_mode) or stat.S_ISLNK(root_before.st_mode):
        reject("repository root must be one real directory")
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "GIT_OPTIONAL_LOCKS": "0",
    }
    try:
        result = subprocess.run(
            [GIT, "ls-files", "--cached", "--stage", "-z", "--"],
            cwd=root,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, OSError) as error:
        reject(f"git index enumeration failed: {error}", ENVIRONMENT_BLOCKED)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace")[-1000:]
        reject(f"git index enumeration failed: {detail}", ENVIRONMENT_BLOCKED)
    root_after = root.lstat()
    if (root_before.st_dev, root_before.st_ino, root_before.st_mode) != (
        root_after.st_dev,
        root_after.st_ino,
        root_after.st_mode,
    ):
        reject("repository root changed during Git index enumeration", CLEANUP_REQUIRED)
    entries = parse_git_tracked_entries(result.stdout)
    if not entries:
        reject("git index contains no tracked files")
    return entries


def _tracked_entry_matches(relative: str, scopes: Sequence[str]) -> bool:
    return any(relative == scope or relative.startswith(scope + "/") for scope in scopes)


def _open_tracked_destination_parent(destination_root_fd: int, relative: str) -> int:
    """Create and open destination ancestors relative to one pinned root FD.

    Every component is opened with ``O_DIRECTORY | O_NOFOLLOW`` before the
    next component is touched.  A concurrent rename therefore leaves us on
    the already-open directory inode instead of following a replacement
    symlink through a later full-path open.
    """
    parts = relative.split("/")
    if not parts or any(part in {"", ".", ".."} or "/" in part for part in parts):
        reject(f"snapshot destination has an unsafe path: {relative}", INTERNAL_ERROR)
    descriptor = os.dup(destination_root_fd)
    accumulated: list[str] = []
    try:
        for component in parts[:-1]:
            accumulated.append(component)
            key = "/".join(accumulated)
            try:
                os.mkdir(component, mode=0o755, dir_fd=descriptor)
            except FileExistsError:
                pass
            except OSError as error:
                reject(
                    f"snapshot destination ancestor could not be created: {key}: {error}",
                    CLEANUP_REQUIRED,
                )
            try:
                next_descriptor = os.open(
                    component,
                    os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                    dir_fd=descriptor,
                )
            except OSError as error:
                reject(
                    f"snapshot destination ancestor became unsafe: {key}: {error}",
                    CLEANUP_REQUIRED,
                )
            os.close(descriptor)
            descriptor = next_descriptor
            info = os.fstat(descriptor)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
                reject(
                    f"snapshot destination ancestor is not a current-user-owned directory: {key}",
                    CLEANUP_REQUIRED,
                )
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _verify_tracked_destination(
    destination_root_fd: int,
    relative_path: Path,
    relative: str,
    expected_identity: tuple[int, int, int, int, int],
    expected_digest: str,
) -> None:
    """Reopen one copied target from the pinned root and bind path to bytes."""
    try:
        verify_fd, verify_info = open_relative_nofollow(
            destination_root_fd,
            relative_path,
            f"snapshot destination {relative}",
        )
    except (OSError, ReleaseUnitError) as error:
        reject(f"snapshot destination changed while copying: {relative}: {error}", CLEANUP_REQUIRED)
    try:
        identity = (
            verify_info.st_dev,
            verify_info.st_ino,
            verify_info.st_mode,
            verify_info.st_nlink,
            verify_info.st_size,
        )
        if (
            not stat.S_ISREG(verify_info.st_mode)
            or verify_info.st_nlink != 1
            or identity != expected_identity
            or sha256_fd(verify_fd) != expected_digest
        ):
            reject(f"snapshot destination changed while copying: {relative}", CLEANUP_REQUIRED)
    finally:
        os.close(verify_fd)


def tracked_worktree_records(
    root: Path,
    entries: Sequence[tuple[int, str]],
    *,
    destination: Path | None = None,
    copy_hook: Callable[[Path, int], None] | None = None,
) -> list[dict[str, Any]]:
    """Hash or copy exact tracked files using nofollow descriptors.

    File bytes come from the live worktree, so tracked uncommitted content is
    retained.  Paths and regular-file modes come from the Git index.  Each
    source descriptor is statted and hashed before and after use, then its path
    is reopened nofollow to detect replacement races.
    """
    root_fd = open_absolute_directory_nofollow(root, "tracked worktree root")
    destination_root_fd: int | None = None
    destination_root_identity: tuple[int, int, int, int] | None = None
    if destination is not None:
        try:
            destination_root_fd = open_absolute_directory_nofollow(
                destination, "snapshot destination root"
            )
        except (OSError, ReleaseUnitError) as error:
            os.close(root_fd)
            reject(f"snapshot destination root is unsafe: {error}", CLEANUP_REQUIRED)
        destination_info = os.fstat(destination_root_fd)
        destination_root_identity = (
            destination_info.st_dev,
            destination_info.st_ino,
            destination_info.st_mode,
            destination_info.st_uid,
        )
    records: list[dict[str, Any]] = []
    try:
        for git_mode, relative in entries:
            if git_mode not in GIT_REGULAR_MODES:
                reject(f"tracked entry mode became unsafe: {relative}", INTERNAL_ERROR)
            relative_path = Path(*relative.split("/"))
            try:
                source_fd, before = open_relative_nofollow(root_fd, relative_path, f"tracked source {relative}")
            except FileNotFoundError:
                reject(f"tracked source is missing: {relative}", ENVIRONMENT_BLOCKED)
            try:
                if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                    reject(f"tracked source must be a single-link regular file: {relative}")
                before_identity = (
                    before.st_dev,
                    before.st_ino,
                    before.st_mode,
                    before.st_nlink,
                    before.st_size,
                    before.st_mtime_ns,
                )
                digest = sha256_fd(source_fd)
                if destination_root_fd is not None:
                    parent_fd = _open_tracked_destination_parent(destination_root_fd, relative)
                    try:
                        try:
                            target_fd = os.open(
                                relative_path.name,
                                os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                stat.S_IMODE(git_mode),
                                dir_fd=parent_fd,
                            )
                        except OSError as error:
                            reject(
                                f"snapshot destination file could not be created: {relative}: {error}",
                                CLEANUP_REQUIRED,
                            )
                        try:
                            os.lseek(source_fd, 0, os.SEEK_SET)
                            copied = 0
                            while payload := os.read(source_fd, 1024 * 1024):
                                view = memoryview(payload)
                                while view:
                                    written = os.write(target_fd, view)
                                    if written <= 0:
                                        reject(f"snapshot write made no progress: {relative}", CLEANUP_REQUIRED)
                                    copied += written
                                    view = view[written:]
                                if copy_hook is not None:
                                    copy_hook(relative_path, copied)
                            os.fchmod(target_fd, stat.S_IMODE(git_mode))
                            target_info = os.fstat(target_fd)
                            target_identity = (
                                target_info.st_dev,
                                target_info.st_ino,
                                target_info.st_mode,
                                target_info.st_nlink,
                                target_info.st_size,
                            )
                        finally:
                            os.close(target_fd)
                    finally:
                        os.close(parent_fd)
                    _verify_tracked_destination(
                        destination_root_fd,
                        relative_path,
                        relative,
                        target_identity,
                        digest,
                    )
                after = os.fstat(source_fd)
                after_identity = (
                    after.st_dev,
                    after.st_ino,
                    after.st_mode,
                    after.st_nlink,
                    after.st_size,
                    after.st_mtime_ns,
                )
                if after_identity != before_identity or sha256_fd(source_fd) != digest:
                    reject(f"tracked source changed while snapshotting: {relative}", CLEANUP_REQUIRED)
            finally:
                os.close(source_fd)
            try:
                verify_fd, verify_info = open_relative_nofollow(root_fd, relative_path, f"tracked source {relative}")
            except FileNotFoundError:
                reject(f"tracked source was replaced while snapshotting: {relative}", CLEANUP_REQUIRED)
            try:
                verify_identity = (
                    verify_info.st_dev,
                    verify_info.st_ino,
                    verify_info.st_mode,
                    verify_info.st_nlink,
                    verify_info.st_size,
                    verify_info.st_mtime_ns,
                )
                if verify_identity != before_identity or sha256_fd(verify_fd) != digest:
                    reject(f"tracked source was replaced while snapshotting: {relative}", CLEANUP_REQUIRED)
            finally:
                os.close(verify_fd)
            records.append(
                {
                    "gid": before.st_gid,
                    "hash": digest,
                    "mode": mode_text(git_mode),
                    "mtimeNs": before.st_mtime_ns,
                    "nlink": before.st_nlink,
                    "path": relative,
                    "size": before.st_size,
                    "type": "file",
                    "uid": before.st_uid,
                }
            )
        if destination is not None and destination_root_identity is not None:
            try:
                verify_root_fd = open_absolute_directory_nofollow(
                    destination, "snapshot destination root verification"
                )
            except (OSError, ReleaseUnitError) as error:
                reject(f"snapshot destination root changed while copying: {error}", CLEANUP_REQUIRED)
            try:
                verify_root_info = os.fstat(verify_root_fd)
                verify_root_identity = (
                    verify_root_info.st_dev,
                    verify_root_info.st_ino,
                    verify_root_info.st_mode,
                    verify_root_info.st_uid,
                )
                if verify_root_identity != destination_root_identity:
                    reject("snapshot destination root changed while copying", CLEANUP_REQUIRED)
            finally:
                os.close(verify_root_fd)
    finally:
        if destination_root_fd is not None:
            os.close(destination_root_fd)
        os.close(root_fd)
    return records


def copy_source(root: Path, destination: Path) -> None:
    """Copy the original six r4a source scopes from the live Git worktree.

    The r4a entrypoint is a repository-root workflow.  A frozen tree without a
    Git index is rejected rather than being recursively re-enumerated.
    """
    if os.path.lexists(destination):
        reject("clean source destination already exists")
    all_entries = git_tracked_entries(root)
    entries = [entry for entry in all_entries if _tracked_entry_matches(entry[1], R4A_SOURCE_PATHS)]
    for scope in R4A_SOURCE_PATHS:
        if not any(_tracked_entry_matches(relative, (scope,)) for _mode, relative in entries):
            reject(f"required tracked r4a source scope is missing: {scope}", ENVIRONMENT_BLOCKED)
    destination.mkdir(mode=0o700)
    tracked_worktree_records(root, entries, destination=destination)


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


def copy_sparkle(root: Path, destination: Path) -> None:
    source = root / SPARKLE_ARTIFACT_RELATIVE
    prefix = "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/"
    allowed_symlinks = {
        prefix + relative: target
        for relative, target in SPARKLE_FRAMEWORK_SYMLINKS.items()
    }
    before = strict_tree_records(source, allowed_symlinks, "offline Sparkle artifact")
    destination.parent.mkdir(mode=0o700, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)
    after_source = strict_tree_records(source, allowed_symlinks, "offline Sparkle artifact")
    after_destination = strict_tree_records(destination, allowed_symlinks, "audit-local Sparkle artifact")
    if before != after_source or before != after_destination:
        reject("offline Sparkle artifact changed while being copied", CLEANUP_REQUIRED)
    license_path = destination / "LICENSE"
    if sha256_file(license_path) != SPARKLE_LICENSE_SHA256:
        reject("Sparkle license hash drifted", ENVIRONMENT_BLOCKED)
    package_manifest = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Sparkle",
  platforms: [.macOS(.v10_13)],
  products: [.library(name: "Sparkle", targets: ["Sparkle"])],
  targets: [.binaryTarget(name: "Sparkle", path: "Sparkle.xcframework")]
)
"""
    (destination / "Package.swift").write_text(package_manifest, encoding="utf-8")
    os.chmod(destination / "Package.swift", 0o644)


def patch_local_dependencies(source: Path, grdb: Path, sparkle: Path) -> None:
    manifest = source / "apps/desktop/Package.swift"
    text = manifest.read_text(encoding="utf-8")
    grdb_remote = '.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")'
    sparkle_remote = '.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")'
    if text.count(grdb_remote) != 1:
        reject("Swift package GRDB declaration drifted", INVALID_UNSAFE)
    if text.count(sparkle_remote) != 1:
        reject("Swift package Sparkle declaration drifted", INVALID_UNSAFE)
    text = text.replace(grdb_remote, f'.package(path: "{grdb}")')
    text = text.replace(sparkle_remote, f'.package(path: "{sparkle}")')
    manifest.write_text(text, encoding="utf-8")


def sync_contracts(source: Path) -> None:
    result = run_command(
        ["/bin/bash", str(source / "scripts/sync-contracts.sh")],
        cwd=source,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
        allowed={"/bin/bash"},
    )
    if result.returncode != 0:
        reject("temporary-source contract synchronization failed", ENVIRONMENT_BLOCKED)


def validate_full_xcode_developer_dir(path: Path) -> str:
    """Validate one complete Xcode developer directory without executing it."""
    if not path.is_absolute() or path.parts[-3:] != ("Xcode.app", "Contents", "Developer"):
        reject("release Xcode developer directory has an unsafe fixed shape")
    if not os.path.lexists(path):
        reject("fixed full Xcode developer directory is missing", ENVIRONMENT_BLOCKED)
    assert_real_components(path, "fixed full Xcode developer directory")
    developer_info = path.lstat()
    if (
        not stat.S_ISDIR(developer_info.st_mode)
        or developer_info.st_uid not in {0, os.geteuid()}
    ):
        reject("fixed full Xcode developer directory is unsafe")

    required_executables = (
        path / "usr/bin/xcodebuild",
        path / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
        path.parent / "SharedFrameworks/XCBuild.framework/Versions/A/XCBuild",
    )
    for executable in required_executables:
        if not os.path.lexists(executable):
            reject(f"full Xcode component is missing: {executable.name}", ENVIRONMENT_BLOCKED)
        assert_real_components(executable, f"full Xcode component {executable.name}")
        try:
            descriptor = os.open(executable, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        except OSError as error:
            if error.errno in {errno.ELOOP, errno.ENOTDIR}:
                reject(f"full Xcode component is unsafe: {executable.name}")
            reject(f"full Xcode component cannot be opened: {executable.name}: {error}", ENVIRONMENT_BLOCKED)
        try:
            info = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid not in {0, os.geteuid()}
            or stat.S_IMODE(info.st_mode) & 0o111 == 0
        ):
            reject(f"full Xcode component is not a trusted executable: {executable.name}")
    return str(path)


def build_swift_products(
    source: Path,
    audit_root: Path,
    architectures: Sequence[str],
) -> tuple[Path, Path, Path]:
    if list(architectures) != stable_host.SUPPORTED_ARCHITECTURES:
        reject(f"Swift build architectures must be exactly {stable_host.SUPPORTED_ARCHITECTURES}")
    developer_dir = validate_full_xcode_developer_dir(XCODE_DEVELOPER_DIR)
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
        "DEVELOPER_DIR": developer_dir,
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
        *(
            argument
            for architecture in architectures
            for argument in ("--arch", architecture)
        ),
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


def app_contract_schema(app: Path) -> Path:
    """定位 App bundle 里随包的合同 schema，兼容两种资源包布局。"""
    bundle = app / "Contents/Resources" / RESOURCE_BUNDLE
    located = stable_host.bundle_resource(bundle, "contracts/capture-envelope-v1.schema.json")
    if located is None:
        reject("App bundle is missing the packaged contract schema")
    return located


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
    # universal 二进制里每个架构各有一条 LC_BUILD_VERSION，所以这里会拿到多个
    # minos。要求它们**全部可解析且完全一致**：只要有一个切片的部署目标和别人不
    # 同，就会出现「在某类 Mac 上装得上、在另一类上直接起不来」这种最难查的故障。
    if not versions or not all(VERSION_RE.fullmatch(value) for value in versions):
        reject("Mach-O must contain parseable LC_BUILD_VERSION minos")
    if len(set(versions)) != 1:
        reject(f"Mach-O slices disagree on minimum macOS: {sorted(set(versions))}")
    components = versions[0].split(".")
    while len(components) > 2 and components[-1] == "0":
        components.pop()
    return ".".join(components)


def macho_rpaths(path: Path) -> list[str]:
    result = command_ok([OTOOL, "-l", str(path)], allowed={OTOOL})
    lines = result.stdout.decode("utf-8", errors="strict").splitlines()
    values: list[str] = []
    reading_rpath = False
    for line in lines:
        stripped = line.strip()
        if stripped == "cmd LC_RPATH":
            reading_rpath = True
            continue
        if reading_rpath:
            match = re.match(r"^path\s+(\S+)\s+\(offset\s+\d+\)$", stripped)
            if match:
                values.append(match.group(1))
                reading_rpath = False
    return values


def macho_linked_libraries(path: Path) -> list[str]:
    result = command_ok([OTOOL, "-L", str(path)], allowed={OTOOL})
    values: list[str] = []
    for line in result.stdout.decode("utf-8", errors="strict").splitlines():
        match = re.match(r"^\s+(\S+)\s+\(compatibility version ", line)
        if match:
            values.append(match.group(1))
    return values


def ensure_sparkle_runtime_rpath(path: Path) -> None:
    """Make the SwiftPM executable resolve the embedded standard framework."""
    slice_count = len(macho_architectures(path))
    current_count = macho_rpaths(path).count(SPARKLE_RUNTIME_RPATH)
    if current_count == 0:
        command_ok(
            [INSTALL_NAME_TOOL, "-add_rpath", SPARKLE_RUNTIME_RPATH, str(path)],
            allowed={INSTALL_NAME_TOOL},
        )
    elif current_count != slice_count:
        reject("App Mach-O slices disagree on the Sparkle runtime search path")
    if macho_rpaths(path).count(SPARKLE_RUNTIME_RPATH) != slice_count:
        reject("App executable is missing the embedded Sparkle runtime search path")


def verify_sparkle_runtime_link(path: Path) -> None:
    slice_count = len(macho_architectures(path))
    if macho_rpaths(path).count(SPARKLE_RUNTIME_RPATH) != slice_count:
        reject("App executable cannot resolve Contents/Frameworks at runtime")
    if macho_linked_libraries(path).count(SPARKLE_INSTALL_NAME) != slice_count:
        reject("App executable Sparkle install name drifted")


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
        # App 的界面和文案以简体中文交付。显式声明支持语言，AppKit 的保存/打开
        # 面板和日期等系统组件才不会在中文系统上回退成英文。
        "CFBundleDevelopmentRegion": "zh-Hans",
        "CFBundleLocalizations": ["zh-Hans"],
        "CFBundleDisplayName": config["appDisplayName"],
        "CFBundleExecutable": config["executable"],
        "CFBundleIconFile": Path(config["iconFile"]).stem,
        "CFBundleIdentifier": config["bundleIdentifier"],
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": config["appDisplayName"],
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": config["shortVersion"],
        "CFBundleURLTypes": [
            {
                "CFBundleURLName": config["bundleIdentifier"],
                "CFBundleURLSchemes": [URL_SCHEME],
            }
        ],
        "CFBundleVersion": config["bundleVersion"],
        "LSApplicationCategoryType": config["category"],
        "LSMinimumSystemVersion": config["minimumMacOS"],
        "NSHighResolutionCapable": True,
        "SUAutomaticallyUpdate": config["sparkleAutomaticallyUpdates"],
        "SUFeedURL": config["sparkleFeedURL"],
        "SUPublicEDKey": config["sparklePublicEDKey"],
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


def strict_tree_records(
    root: Path,
    allowed_symlinks: dict[str, str],
    label: str,
) -> list[dict[str, Any]]:
    if root.is_symlink() or not root.is_dir():
        reject(f"{label} root must be a real directory")
    records: list[dict[str, Any]] = []
    seen_symlinks: set[str] = set()
    paths: list[Path] = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        paths.extend(Path(current) / name for name in directories + files)
    for path in sorted(paths, key=lambda item: os.fsencode(item.relative_to(root).as_posix())):
        relative = path.relative_to(root).as_posix()
        if not relative or relative.startswith("/") or any(part in {"", ".", ".."} for part in PurePosixPath(relative).parts):
            reject(f"{label} contains an unsafe relative path")
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            if allowed_symlinks.get(relative) != target:
                reject(f"{label} contains an unexpected symlink: {relative}")
            seen_symlinks.add(relative)
            records.append({
                "hash": sha256_bytes(target.encode("utf-8")),
                "mode": mode_text(info.st_mode),
                "path": relative,
                "size": len(target.encode("utf-8")),
                "type": "symlink",
            })
        elif stat.S_ISDIR(info.st_mode):
            records.append({"hash": None, "mode": mode_text(info.st_mode), "path": relative, "size": 0, "type": "directory"})
        elif stat.S_ISREG(info.st_mode):
            if info.st_nlink != 1:
                reject(f"{label} contains a hardlinked file: {relative}")
            records.append({
                "hash": sha256_file(path),
                "mode": mode_text(info.st_mode),
                "path": relative,
                "size": info.st_size,
                "type": "file",
            })
        else:
            reject(f"{label} contains an unsupported entry: {relative}")
    if seen_symlinks != set(allowed_symlinks):
        reject(f"{label} symlink set does not match the frozen Sparkle layout")
    return records


def sparkle_framework_records(framework: Path) -> list[dict[str, Any]]:
    return strict_tree_records(framework, SPARKLE_FRAMEWORK_SYMLINKS, SPARKLE_FRAMEWORK)


def copy_sparkle_framework(source: Path, destination: Path) -> None:
    before = sparkle_framework_records(source)
    shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)
    after_source = sparkle_framework_records(source)
    after_destination = sparkle_framework_records(destination)
    if before != after_source or before != after_destination:
        reject("Sparkle.framework changed while being embedded", CLEANUP_REQUIRED)


def verified_browser_extension_payloads(source_root: Path) -> tuple[list[tuple[PurePosixPath, bytes]], dict[str, Any]]:
    """读取并校验冻结的 Chromium 扩展交付包。

    `.output` 是本机临时产物，发布审计的 source copy 里不存在。App 内置的扩展必须来自
    已冻结、带稳定 ID 的 identity artifact；同时逐项拒绝绝对路径、`..`、目录项和特殊项，
    避免把 ZIP 当成可信目录直接解压。
    """
    identity = load_json(source_root / BROWSER_EXTENSION_IDENTITY, "extension identity config")
    display = load_json(source_root / PRODUCT_DISPLAY, "product display config")
    artifact_text = identity.get("artifactSource")
    if not isinstance(artifact_text, str):
        reject("extension identity artifactSource must be a relative path")
    artifact_relative = PurePosixPath(artifact_text)
    if artifact_relative.is_absolute() or any(part in {"", ".", ".."} for part in artifact_relative.parts):
        reject("extension identity artifactSource is unsafe")
    artifact = source_root.joinpath(*artifact_relative.parts)
    if artifact.is_symlink() or not artifact.is_file():
        reject("extension identity artifact is missing or unsafe")
    try:
        with zipfile.ZipFile(artifact, "r") as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if names != byte_sorted(names) or len(names) != len(set(names)) or "manifest.json" not in names:
                reject("extension identity artifact entries are not exact")
            payloads: list[tuple[PurePosixPath, bytes]] = []
            for info in infos:
                relative = PurePosixPath(info.filename)
                if (
                    info.is_dir()
                    or relative.is_absolute()
                    or any(part in {"", ".", ".."} for part in relative.parts)
                    or info.file_size > 16 * 1024 * 1024
                ):
                    reject("extension identity artifact contains an unsafe entry")
                payloads.append((relative, archive.read(info)))
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, ReleaseUnitError):
            raise
        reject(f"extension identity artifact is invalid: {error}")
    try:
        manifest = json.loads(dict((path.as_posix(), data) for path, data in payloads)["manifest.json"].decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError, KeyError) as error:
        reject(f"extension identity artifact manifest is invalid: {error}")
    if not isinstance(manifest, dict):
        reject("extension identity artifact manifest must be one JSON object")
    for field, expected in {
        "key": identity.get("manifestKey"),
        "name": display.get("displayName"),
        "description": display.get("extensionDescription"),
        "version": identity.get("version"),
    }.items():
        if not isinstance(expected, str) or manifest.get(field) != expected:
            reject(f"extension identity artifact manifest {field} drifted")
    return payloads, manifest


def embed_browser_extension(source_root: Path, destination: Path) -> None:
    if os.path.lexists(destination):
        reject("embedded browser extension destination already exists")
    payloads, _ = verified_browser_extension_payloads(source_root)
    destination.mkdir(mode=0o755)
    for relative, payload in payloads:
        target = destination.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        target.write_bytes(payload)
        os.chmod(target, 0o644)


def verify_browser_extension(app: Path, source_root: Path) -> dict[str, Any]:
    embedded = app / "Contents/Resources" / BROWSER_EXTENSION_DIRECTORY
    if embedded.is_symlink() or not embedded.is_dir():
        reject("embedded browser extension directory is missing or unsafe")
    payloads, manifest = verified_browser_extension_payloads(source_root)
    expected = {path.as_posix(): sha256_bytes(payload) for path, payload in payloads}
    actual: dict[str, str] = {}
    for current, directories, files in os.walk(embedded, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        for name in directories:
            path = Path(current) / name
            if path.is_symlink():
                reject("embedded browser extension contains a symlink")
        for name in files:
            path = Path(current) / name
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                reject("embedded browser extension contains an unsafe file")
            actual[path.relative_to(embedded).as_posix()] = sha256_file(path)
    if actual != expected:
        reject("embedded browser extension drifted from frozen identity artifact")
    return {
        "directory": BROWSER_EXTENSION_DIRECTORY,
        "fileCount": len(actual),
        "version": manifest["version"],
    }


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
    frameworks = output / "Contents/Frameworks"
    resources = output / "Contents/Resources"
    native_host = resources / "NativeHost"
    macos.mkdir(parents=True, mode=0o755)
    frameworks.mkdir(parents=True, mode=0o755)
    native_host.mkdir(parents=True, mode=0o755)
    copy_path_nofollow(
        app_binary.parent,
        Path(app_binary.name),
        macos / app_config["executable"],
        excluded_names=set(),
        label="Release App executable",
    )
    app_executable = macos / app_config["executable"]
    os.chmod(app_executable, 0o755)
    ensure_sparkle_runtime_rpath(app_executable)
    sparkle_framework = app_binary.parent / SPARKLE_FRAMEWORK
    if not sparkle_framework.is_dir() or sparkle_framework.is_symlink():
        reject("Release Sparkle.framework is missing", ENVIRONMENT_BLOCKED)
    copy_sparkle_framework(sparkle_framework, frameworks / SPARKLE_FRAMEWORK)
    copy_resource_tree(resource_bundle, resources / RESOURCE_BUNDLE)
    embed_browser_extension(source_root, resources / BROWSER_EXTENSION_DIRECTORY)
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
        source_root,
        Path("licenses"),
        resources / THIRD_PARTY_LICENSES_DIRECTORY,
        excluded_names=set(),
        label="third-party license notices",
    )
    copy_path_nofollow(
        host_package.parent,
        Path(host_package.name),
        native_host / host_package.name,
        excluded_names=set(),
        label="verified Host package",
    )
    write_plist(output / "Contents/Info.plist", info_plist(app_config))
    for directory in (output, output / "Contents", macos, frameworks, resources, native_host):
        os.chmod(directory, 0o755)
    return output


def release_tree_records(root: Path) -> tuple[list[dict[str, Any]], str]:
    prefix = f"Contents/Frameworks/{SPARKLE_FRAMEWORK}/"
    allowed_symlinks = {
        prefix + relative: target
        for relative, target in SPARKLE_FRAMEWORK_SYMLINKS.items()
    }
    records = strict_tree_records(root, allowed_symlinks, "release App tree")
    digest = sha256_bytes(canonical_bytes(records))
    return records, digest


def exact_app_paths(
    app: Path,
    host_name: str,
    icon_file: str,
    *,
    signed: bool = False,
) -> None:
    top = {path.name for path in app.iterdir()}
    if top != {"Contents"}:
        reject("App bundle top-level tree is not exact")
    expected_contents = {"Frameworks", "Info.plist", "MacOS", "Resources"}
    if signed:
        expected_contents.add("_CodeSignature")
    contents = {path.name for path in (app / "Contents").iterdir()}
    if contents != expected_contents:
        reject("App Contents tree is not exact")
    if signed:
        code_signature = app / "Contents/_CodeSignature"
        if {path.name for path in code_signature.iterdir()} != {"CodeResources"}:
            reject("signed App code-signature tree is not exact")
    macos = {path.name for path in (app / "Contents/MacOS").iterdir()}
    if macos != {"LinkDigestApp"}:
        reject("App MacOS tree is not exact")
    frameworks = {path.name for path in (app / "Contents/Frameworks").iterdir()}
    if frameworks != {SPARKLE_FRAMEWORK}:
        reject("App Frameworks tree is not exact")
    resources = {path.name for path in (app / "Contents/Resources").iterdir()}
    if resources != {
        RESOURCE_BUNDLE,
        "NativeHost",
        icon_file,
        PLATFORM_ICONS_DIRECTORY,
        PROVIDER_ICONS_DIRECTORY,
        THIRD_PARTY_LICENSES_DIRECTORY,
        BROWSER_EXTENSION_DIRECTORY,
    }:
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


def verify_sparkle_framework(app: Path) -> dict[str, Any]:
    framework = app / "Contents/Frameworks" / SPARKLE_FRAMEWORK
    records = sparkle_framework_records(framework)
    info_path = framework / "Versions/B/Resources/Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        reject(f"Sparkle.framework Info.plist is invalid: {error}")
    if (
        not isinstance(info, dict)
        or info.get("CFBundleIdentifier") != "org.sparkle-project.Sparkle"
        or info.get("CFBundleShortVersionString") != SPARKLE_VERSION
    ):
        reject("Sparkle.framework identity or version drifted")
    executable = framework / "Versions/B/Sparkle"
    architectures = macho_architectures(executable)
    if sorted(architectures) != sorted(stable_host.SUPPORTED_ARCHITECTURES):
        reject("Sparkle.framework must remain universal")
    command_ok([CODESIGN, "--verify", "--deep", "--strict", str(framework)], allowed={CODESIGN})
    return {
        "architectures": architectures,
        "treeDigest": sha256_bytes(canonical_bytes(records)),
        "version": SPARKLE_VERSION,
    }


def verify_third_party_licenses(app: Path, source_root: Path) -> dict[str, str]:
    embedded_root = app / "Contents/Resources" / THIRD_PARTY_LICENSES_DIRECTORY
    source_licenses = source_root / "licenses"
    if {path.name for path in embedded_root.iterdir()} != set(THIRD_PARTY_LICENSE_HASHES):
        reject("embedded third-party license set is not exact")
    hashes: dict[str, str] = {}
    for name, expected_hash in THIRD_PARTY_LICENSE_HASHES.items():
        embedded = embedded_root / name
        source = source_licenses / name
        for path, label in ((embedded, "embedded license"), (source, "source license")):
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                reject(f"{label} must be a single-link regular file")
        digest = sha256_file(embedded)
        if digest != expected_hash or sha256_file(source) != expected_hash:
            reject(f"third-party license hash drifted: {name}")
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
    browser_extension = verify_browser_extension(app, source_root)
    sparkle = verify_sparkle_framework(app)
    third_party_licenses = verify_third_party_licenses(app, source_root)
    app_executable = app / "Contents/MacOS/LinkDigestApp"
    verify_sparkle_runtime_link(app_executable)
    host_package = app / "Contents/Resources/NativeHost" / host_package_name
    verified_host = verify_host_package(host_package, source_root)
    app_arch = macho_architectures(app_executable)
    app_minimum = macho_minimum_macos(app_executable)
    host_executable = host_package / verified_host.config["entrypoint"]
    host_arch = macho_architectures(host_executable)
    host_minimum = macho_minimum_macos(host_executable)
    # 排序后比较：`lipo -archs` 不保证输出顺序与配置书写顺序一致。
    expected_arch = sorted(app_config["architectures"])
    if sorted(app_arch) != expected_arch or sorted(host_arch) != expected_arch:
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
        "browserExtension": browser_extension,
        "sparkle": sparkle,
        "thirdPartyLicenses": third_party_licenses,
        "minimumMacOS": app_minimum,
        "plist": plist,
        "plistHash": plist_hash,
        # 资源包内布局随构建方式而变（universal 是标准 macOS 包，单架构是扁平
        # 包），所以让 stable_host 去按两种布局定位，不在这里写死路径。
        "schemaHash": sha256_file(app_contract_schema(app)),
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
            "sparkle": app_result["sparkle"],
            "thirdPartyLicenses": app_result["thirdPartyLicenses"],
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
        reject(f"DMG staging root must contain exactly {APP_BUNDLE} and {RELEASE_UNIT_NAME}")
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
    grdb_dependency = audit_root / "dependencies/GRDB.swift"
    sparkle_dependency = audit_root / "dependencies/Sparkle"
    output = audit_root / "output"
    staging = audit_root / "staging"
    output.mkdir(mode=0o700)
    staging.mkdir(mode=0o755)
    try:
        app_config = load_app_config(root)
        copy_source(root, source)
        copy_grdb(root, grdb_dependency)
        copy_sparkle(root, sparkle_dependency)
        patch_local_dependencies(source, grdb_dependency, sparkle_dependency)
        sync_contracts(source)
        app_binary, host_binary, resource_bundle = build_swift_products(
            source,
            audit_root,
            app_config["architectures"],
        )

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
