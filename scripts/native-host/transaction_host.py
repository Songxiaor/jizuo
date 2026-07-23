#!/usr/bin/env python3
"""Crash-recoverable clean-room transactions for the LinkDigest Native Host.

All mutations are anchored to a verified clean-room directory descriptor.  The
module is intentionally standard-library-only and has no real-HOME mode.
"""

from __future__ import annotations

import argparse
import base64
import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable, Sequence

import stable_host


SUCCESS = 0
INVALID_UNSAFE = 2
LOCK_BUSY = 3
STALE_PLAN = 4
ACTIVE_TRANSACTION = 5
OWNERSHIP_DRIFT = 6
ROLLED_BACK = 7
RECOVERY_REQUIRED = 8
INTERNAL_ERROR = 70

RECEIPT_V1 = "receipt-v1.json"
RECEIPT_V2 = "receipt-v2.json"
LOCK_NAME = ".transaction.lock"
LOCK_CONTENT = b"LinkDigest transaction lock v1\n"
TRANSACTIONS = "transactions"
JOURNAL = "journal.json"
JOURNAL_FORMAT = 1
PLAN_FORMAT = 1
RECEIPT_FORMAT = 2
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MODE_RE = re.compile(r"^0[0-7]{3}$")
SAFE_TXID_RE = re.compile(r"^[0-9a-f]{32}$")

O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)


class TransactionError(RuntimeError):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code


class BarrierError(RuntimeError):
    pass


def reject(message: str, code: int = INVALID_UNSAFE) -> "None":
    raise TransactionError(code, message)


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def digest_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def require_exact_keys(value: object, keys: set[str], label: str) -> dict:
    if not isinstance(value, dict) or set(value) != keys:
        reject(f"{label} fields do not match the strict format")
    return value


def require_string(value: object, label: str) -> str:
    if not isinstance(value, str):
        reject(f"{label} must be a string")
    return value


def require_hash(value: object, label: str) -> str:
    text = require_string(value, label)
    if not SHA256_RE.fullmatch(text):
        reject(f"{label} must be a lowercase SHA-256")
    return text


def require_mode(value: object, label: str) -> str:
    text = require_string(value, label)
    if not MODE_RE.fullmatch(text):
        reject(f"{label} must be an octal mode string")
    return text


def mode_text(mode: int) -> str:
    return f"0{stat.S_IMODE(mode):03o}"


def safe_relative(text: str, *, allow_dot: bool = False) -> tuple[str, ...]:
    if text == "." and allow_dot:
        return ()
    if not text or text.startswith("/") or "\x00" in text or "\\" in text:
        reject(f"unsafe relative path: {text!r}")
    path = PurePosixPath(text)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        reject(f"unsafe relative path: {text!r}")
    return path.parts


def byte_sorted(values: Iterable[str]) -> list[str]:
    return sorted(values, key=os.fsencode)


def semver_key(version: str) -> tuple[tuple[int, int, int], tuple[tuple[int, object], ...]]:
    if not stable_host.SEMVER_RE.fullmatch(version):
        reject(f"unsafe product version: {version}")
    core_and_pre = version.split("+", 1)[0]
    core, separator, pre = core_and_pre.partition("-")
    core_key = tuple(int(part) for part in core.split("."))
    if not separator:
        return core_key, ((2, ""),)
    pre_key: list[tuple[int, object]] = []
    for item in pre.split("."):
        pre_key.append((0, int(item)) if item.isdigit() else (1, item))
    return core_key, tuple(pre_key)


def ensure_semver(value: object, label: str) -> str:
    text = require_string(value, label)
    semver_key(text)
    return text


@dataclass(frozen=True)
class CleanRoom:
    session: Path
    home: Path
    home_rel: str
    session_fd: int

    def close(self) -> None:
        os.close(self.session_fd)


def _open_absolute_directory(path: Path) -> int:
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
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _validate_owned_directory(descriptor: int, label: str, mode: int = 0o700) -> None:
    info = os.fstat(descriptor)
    if not stat.S_ISDIR(info.st_mode):
        reject(f"{label} is not a directory")
    if info.st_uid != os.geteuid():
        reject(f"{label} is not owned by the effective user")
    if stat.S_IMODE(info.st_mode) != mode:
        reject(f"{label} mode must be {mode:04o}")


def validate_clean_room(session_text: str, home_text: str) -> CleanRoom:
    try:
        validated = stable_host.validate_clean_room(Path(session_text), Path(home_text))
    except stable_host.StableHostError as error:
        reject(str(error))
    session_fd = _open_absolute_directory(validated.session_root)
    try:
        _validate_owned_directory(session_fd, "session root")
        home_name = validated.home_root.name
        home_fd = os.open(
            home_name,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            dir_fd=session_fd,
        )
        try:
            _validate_owned_directory(home_fd, "home root")
        finally:
            os.close(home_fd)
        sentinel_fd = os.open(
            stable_host.CLEAN_ROOM_SENTINEL,
            os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            dir_fd=session_fd,
        )
        try:
            info = os.fstat(sentinel_fd)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1
            ):
                reject("clean-room sentinel type/owner/mode/link-count is unsafe")
            payload = b""
            while True:
                chunk = os.read(sentinel_fd, 4096)
                if not chunk:
                    break
                payload += chunk
                if len(payload) > 4096:
                    reject("clean-room sentinel is oversized")
            if payload != stable_host.CLEAN_ROOM_SENTINEL_CONTENT.encode("utf-8"):
                reject("clean-room sentinel content is invalid")
        finally:
            os.close(sentinel_fd)
        try:
            lock_fd = os.open(
                LOCK_NAME,
                os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                dir_fd=session_fd,
            )
        except OSError as error:
            reject(f"transaction lock is missing or unsafe: {error}")
        try:
            info = os.fstat(lock_fd)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1
            ):
                reject("transaction lock type/owner/mode/link-count is unsafe")
            payload = os.read(lock_fd, len(LOCK_CONTENT) + 1)
            if payload != LOCK_CONTENT:
                reject("transaction lock content is invalid")
        finally:
            os.close(lock_fd)
        return CleanRoom(validated.session_root, validated.home_root, home_name, session_fd)
    except BaseException:
        os.close(session_fd)
        raise


class DirTree:
    """Mutation layer anchored to the already-validated session dirfd."""

    def __init__(self, root_fd: int, root_path: Path) -> None:
        self.root_fd = os.dup(root_fd)
        self.root_path = root_path
        info = os.fstat(self.root_fd)
        self.root_identity = (info.st_dev, info.st_ino)

    def close(self) -> None:
        os.close(self.root_fd)

    def assert_anchor(self) -> None:
        try:
            descriptor = _open_absolute_directory(self.root_path)
        except (FileNotFoundError, NotADirectoryError, OSError) as error:
            reject(f"clean-room session anchor cannot be reopened: {error}", RECOVERY_REQUIRED)
        try:
            info = os.fstat(descriptor)
            if (info.st_dev, info.st_ino) != self.root_identity:
                reject("clean-room session anchor identity changed", RECOVERY_REQUIRED)
        finally:
            os.close(descriptor)

    def _parts(self, relative: str, *, allow_dot: bool = False) -> tuple[str, ...]:
        return safe_relative(relative, allow_dot=allow_dot)

    def open_dir(self, relative: str, *, create: bool = False) -> int:
        parts = self._parts(relative, allow_dot=True)
        descriptor = os.dup(self.root_fd)
        try:
            for component in parts:
                try:
                    next_descriptor = os.open(
                        component,
                        os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                        dir_fd=descriptor,
                    )
                except FileNotFoundError:
                    if not create:
                        raise
                    self.assert_anchor()
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    os.fsync(descriptor)
                    next_descriptor = os.open(
                        component,
                        os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                        dir_fd=descriptor,
                    )
                _validate_owned_directory(next_descriptor, f"directory {relative}")
                os.close(descriptor)
                descriptor = next_descriptor
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def ensure_dir(self, relative: str) -> None:
        self.assert_anchor()
        descriptor = self.open_dir(relative, create=True)
        os.close(descriptor)

    def _parent(self, relative: str, *, create: bool = False) -> tuple[int, str]:
        parts = self._parts(relative)
        parent = "/".join(parts[:-1]) if len(parts) > 1 else "."
        return self.open_dir(parent, create=create), parts[-1]

    def lexists(self, relative: str) -> bool:
        try:
            parent, name = self._parent(relative)
        except FileNotFoundError:
            return False
        try:
            os.stat(name, dir_fd=parent, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False
        finally:
            os.close(parent)

    def lstat(self, relative: str) -> os.stat_result:
        parent, name = self._parent(relative)
        try:
            return os.stat(name, dir_fd=parent, follow_symlinks=False)
        finally:
            os.close(parent)

    def listdir(self, relative: str) -> list[str]:
        descriptor = self.open_dir(relative)
        try:
            return byte_sorted(os.listdir(descriptor))
        finally:
            os.close(descriptor)

    @staticmethod
    def _validate_file_info(info: os.stat_result, label: str, mode: int | None = None) -> None:
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            reject(f"{label} type/owner/link-count is unsafe", OWNERSHIP_DRIFT)
        if mode is not None and stat.S_IMODE(info.st_mode) != mode:
            reject(f"{label} mode drifted", OWNERSHIP_DRIFT)

    def read_file(self, relative: str, *, mode: int | None = None, limit: int | None = None) -> bytes:
        parent, name = self._parent(relative)
        descriptor: int | None = None
        try:
            try:
                descriptor = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, dir_fd=parent)
            except OSError as error:
                reject(f"unsafe file leaf {relative}: {error}", OWNERSHIP_DRIFT)
            info = os.fstat(descriptor)
            self._validate_file_info(info, relative, mode)
            if limit is not None and info.st_size > limit:
                reject(f"{relative} exceeds its size limit", OWNERSHIP_DRIFT)
            chunks: list[bytes] = []
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            return b"".join(chunks)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(parent)

    def hash_file(self, relative: str, *, mode: int | None = None) -> str:
        return digest_bytes(self.read_file(relative, mode=mode))

    def write_exclusive(self, relative: str, payload: bytes, mode: int) -> None:
        self.assert_anchor()
        parent, name = self._parent(relative, create=True)
        descriptor: int | None = None
        try:
            descriptor = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode,
                dir_fd=parent,
            )
            os.fchmod(descriptor, mode)
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
            os.fsync(descriptor)
            self._validate_file_info(os.fstat(descriptor), relative, mode)
            os.fsync(parent)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(parent)

    def write_atomic(
        self,
        relative: str,
        payload: bytes,
        mode: int,
        nonce: str,
        *,
        expected_existing_hash: str | None = None,
    ) -> None:
        self.assert_anchor()
        parent, name = self._parent(relative, create=True)
        temporary = f".{name}.{nonce}.next"
        descriptor: int | None = None
        existing_fd: int | None = None
        temporary_identity: tuple[int, int] | None = None
        try:
            existing_fd = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, dir_fd=parent)
            existing_info = os.fstat(existing_fd)
            self._validate_file_info(existing_info, relative, mode)
            existing_payload = self._read_descriptor(existing_fd)
            if expected_existing_hash is not None and digest_bytes(existing_payload) != expected_existing_hash:
                reject(f"atomic replace precondition drifted: {relative}", OWNERSHIP_DRIFT)
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode,
                dir_fd=parent,
            )
            opened_temporary_info = os.fstat(descriptor)
            temporary_identity = (opened_temporary_info.st_dev, opened_temporary_info.st_ino)
            os.fchown(descriptor, existing_info.st_uid, existing_info.st_gid)
            os.fchmod(descriptor, mode)
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
            os.fsync(descriptor)
            self._validate_file_info(os.fstat(descriptor), temporary, mode)
            temporary_info = os.fstat(descriptor)
            if temporary_info.st_uid != existing_info.st_uid or temporary_info.st_gid != existing_info.st_gid:
                reject(f"atomic replace did not preserve uid/gid: {relative}", RECOVERY_REQUIRED)
            temporary_identity = (temporary_info.st_dev, temporary_info.st_ino)
            os.close(descriptor)
            descriptor = None
            current_info = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (current_info.st_dev, current_info.st_ino) != (existing_info.st_dev, existing_info.st_ino):
                reject(f"atomic replace target changed after validation: {relative}", OWNERSHIP_DRIFT)
            self.assert_anchor()
            os.rename(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
            replaced = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (replaced.st_dev, replaced.st_ino) != (temporary_info.st_dev, temporary_info.st_ino):
                reject(f"atomic replace result identity is unexpected: {relative}", RECOVERY_REQUIRED)
            if (
                replaced.st_uid != existing_info.st_uid
                or replaced.st_gid != existing_info.st_gid
                or stat.S_IMODE(replaced.st_mode) != mode
                or replaced.st_nlink != 1
            ):
                reject(f"atomic replace result metadata drifted: {relative}", RECOVERY_REQUIRED)
        except BaseException:
            if temporary_identity is not None:
                try:
                    current_temporary = os.stat(temporary, dir_fd=parent, follow_symlinks=False)
                    if (current_temporary.st_dev, current_temporary.st_ino) == temporary_identity:
                        self.assert_anchor()
                        os.unlink(temporary, dir_fd=parent)
                        os.fsync(parent)
                except FileNotFoundError:
                    pass
            raise
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if existing_fd is not None:
                os.close(existing_fd)
            os.close(parent)

    @staticmethod
    def _read_descriptor(descriptor: int) -> bytes:
        os.lseek(descriptor, 0, os.SEEK_SET)
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)

    def copy_file_from_path(self, source: Path, destination: str, mode: int) -> None:
        self.assert_anchor()
        source_fd = os.open(source, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        parent, name = self._parent(destination, create=True)
        destination_fd: int | None = None
        try:
            source_info = os.fstat(source_fd)
            if (
                not stat.S_ISREG(source_info.st_mode)
                or source_info.st_uid != os.geteuid()
                or source_info.st_nlink != 1
            ):
                reject(f"package source changed type: {source}")
            destination_fd = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode,
                dir_fd=parent,
            )
            os.fchmod(destination_fd, mode)
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                offset = 0
                while offset < len(chunk):
                    offset += os.write(destination_fd, chunk[offset:])
            os.fsync(destination_fd)
            self._validate_file_info(os.fstat(destination_fd), destination, mode)
            os.fsync(parent)
        finally:
            if destination_fd is not None:
                os.close(destination_fd)
            os.close(parent)
            os.close(source_fd)

    def rename(
        self,
        source: str,
        destination: str,
        *,
        create_destination_parent: bool = False,
        expect_destination_absent: bool = True,
    ) -> None:
        self.assert_anchor()
        source_parent, source_name = self._parent(source)
        destination_parent, destination_name = self._parent(destination, create=create_destination_parent)
        try:
            source_info = os.stat(source_name, dir_fd=source_parent, follow_symlinks=False)
            if source_info.st_uid != os.geteuid() or not (
                stat.S_ISREG(source_info.st_mode) or stat.S_ISDIR(source_info.st_mode)
            ):
                reject(f"rename source type/owner is unsafe: {source}", OWNERSHIP_DRIFT)
            if stat.S_ISREG(source_info.st_mode) and source_info.st_nlink != 1:
                reject(f"rename source link-count is unsafe: {source}", OWNERSHIP_DRIFT)
            if expect_destination_absent:
                try:
                    os.stat(destination_name, dir_fd=destination_parent, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    reject(f"rename destination must be absent: {destination}", OWNERSHIP_DRIFT)
            self.assert_anchor()
            if expect_destination_absent:
                try:
                    os.stat(destination_name, dir_fd=destination_parent, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    reject(f"rename destination appeared before mutation: {destination}", OWNERSHIP_DRIFT)
            os.rename(
                source_name,
                destination_name,
                src_dir_fd=source_parent,
                dst_dir_fd=destination_parent,
            )
            os.fsync(source_parent)
            if destination_parent != source_parent:
                os.fsync(destination_parent)
            destination_info = os.stat(destination_name, dir_fd=destination_parent, follow_symlinks=False)
            if (destination_info.st_dev, destination_info.st_ino) != (source_info.st_dev, source_info.st_ino):
                reject(f"rename result identity is unexpected: {destination}", RECOVERY_REQUIRED)
        finally:
            os.close(destination_parent)
            os.close(source_parent)

    def unlink_file(self, relative: str, *, expected_hash: str | None = None, mode: int | None = None) -> None:
        self.assert_anchor()
        parent, name = self._parent(relative)
        descriptor: int | None = None
        try:
            descriptor = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, dir_fd=parent)
            info = os.fstat(descriptor)
            self._validate_file_info(info, relative, mode)
            if expected_hash is not None and digest_bytes(self._read_descriptor(descriptor)) != expected_hash:
                reject(f"refusing to unlink modified file: {relative}", OWNERSHIP_DRIFT)
            current_info = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (current_info.st_dev, current_info.st_ino) != (info.st_dev, info.st_ino):
                reject(f"unlink target changed after validation: {relative}", OWNERSHIP_DRIFT)
            self.assert_anchor()
            os.unlink(name, dir_fd=parent)
            os.fsync(parent)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(parent)

    def copy_file_preserve(self, source: str, destination: str) -> os.stat_result:
        self.assert_anchor()
        source_parent, source_name = self._parent(source)
        destination_parent, destination_name = self._parent(destination, create=True)
        source_fd: int | None = None
        destination_fd: int | None = None
        try:
            source_fd = os.open(source_name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=source_parent)
            source_info = os.fstat(source_fd)
            self._validate_file_info(source_info, source)
            payload = self._read_descriptor(source_fd)
            destination_fd = os.open(
                destination_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                stat.S_IMODE(source_info.st_mode),
                dir_fd=destination_parent,
            )
            os.fchown(destination_fd, source_info.st_uid, source_info.st_gid)
            os.fchmod(destination_fd, stat.S_IMODE(source_info.st_mode))
            offset = 0
            while offset < len(payload):
                offset += os.write(destination_fd, payload[offset:])
            os.fsync(destination_fd)
            destination_info = os.fstat(destination_fd)
            self._validate_file_info(destination_info, destination, stat.S_IMODE(source_info.st_mode))
            if (
                destination_info.st_uid != source_info.st_uid
                or destination_info.st_gid != source_info.st_gid
            ):
                reject(f"preserving copy metadata/bytes mismatch: {destination}", RECOVERY_REQUIRED)
            os.fsync(destination_parent)
            verify_fd = os.open(destination_name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=destination_parent)
            try:
                if digest_bytes(self._read_descriptor(verify_fd)) != digest_bytes(payload):
                    reject(f"preserving copy bytes mismatch: {destination}", RECOVERY_REQUIRED)
            finally:
                os.close(verify_fd)
            return source_info
        finally:
            if destination_fd is not None:
                os.close(destination_fd)
            if source_fd is not None:
                os.close(source_fd)
            os.close(destination_parent)
            os.close(source_parent)

    def copy_package_tree(self, source: Path, destination: str, entrypoint: str) -> None:
        if self.lexists(destination):
            reject(f"staging destination already exists: {destination}", OWNERSHIP_DRIFT)
        self.ensure_dir(destination)

        def copy(source_dir: Path, destination_dir: str, relative: str) -> None:
            with os.scandir(source_dir) as entries:
                ordered = sorted(entries, key=lambda item: os.fsencode(item.name))
            for entry in ordered:
                info = entry.stat(follow_symlinks=False)
                child_relative = entry.name if relative == "." else f"{relative}/{entry.name}"
                child_destination = f"{destination_dir}/{entry.name}"
                if stat.S_ISDIR(info.st_mode):
                    self.ensure_dir(child_destination)
                    copy(Path(entry.path), child_destination, child_relative)
                elif stat.S_ISREG(info.st_mode):
                    mode = 0o755 if child_relative == entrypoint else 0o600
                    self.copy_file_from_path(Path(entry.path), child_destination, mode)
                else:
                    reject(f"package source changed to an unsafe entry: {child_relative}")

        copy(source, destination, ".")

    def snapshot_tree(self, relative: str) -> tuple[list[dict], list[dict]]:
        directories: list[dict] = []
        files: list[dict] = []

        def walk(directory_relative: str, record_relative: str) -> None:
            descriptor = self.open_dir(directory_relative)
            try:
                info = os.fstat(descriptor)
                if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                    reject(f"installed directory mode/owner drifted: {directory_relative}", OWNERSHIP_DRIFT)
                directories.append({"mode": "0700", "path": record_relative})
                names = byte_sorted(os.listdir(descriptor))
                for name in names:
                    child_info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                    child_record = name if record_relative == "." else f"{record_relative}/{name}"
                    child_relative = f"{directory_relative}/{name}"
                    if stat.S_ISDIR(child_info.st_mode):
                        walk(child_relative, child_record)
                    elif stat.S_ISREG(child_info.st_mode):
                        self._validate_file_info(child_info, child_relative)
                        file_mode = mode_text(child_info.st_mode)
                        if file_mode not in {"0600", "0755"}:
                            reject(f"installed file mode drifted: {child_relative}", OWNERSHIP_DRIFT)
                        files.append({"hash": self.hash_file(child_relative), "mode": file_mode, "path": child_record})
                    else:
                        reject(f"installed tree contains an unsafe entry: {child_relative}", OWNERSHIP_DRIFT)
            finally:
                os.close(descriptor)

        walk(relative, ".")
        directories.sort(key=lambda item: os.fsencode(item["path"]))
        files.sort(key=lambda item: os.fsencode(item["path"]))
        return directories, files

    def verify_tree(self, relative: str, record: dict) -> None:
        directories, files = self.snapshot_tree(relative)
        if directories != record["directories"] or files != record["files"]:
            reject(f"installed tree differs from receipt: {relative}", OWNERSHIP_DRIFT)

    def remove_tree(self, relative: str, record: dict | None = None) -> None:
        self.assert_anchor()
        if record is not None:
            self.verify_tree(relative, record)

        def remove(directory_relative: str) -> None:
            descriptor = self.open_dir(directory_relative)
            try:
                for name in byte_sorted(os.listdir(descriptor)):
                    info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                    if stat.S_ISDIR(info.st_mode):
                        remove(f"{directory_relative}/{name}")
                    elif stat.S_ISREG(info.st_mode):
                        self._validate_file_info(info, f"{directory_relative}/{name}")
                        self.assert_anchor()
                        os.unlink(name, dir_fd=descriptor)
                        os.fsync(descriptor)
                    else:
                        reject(f"refusing to remove unsafe transaction entry: {directory_relative}/{name}", RECOVERY_REQUIRED)
            finally:
                os.close(descriptor)
            parent, name = self._parent(directory_relative)
            try:
                self.assert_anchor()
                os.rmdir(name, dir_fd=parent)
                os.fsync(parent)
            finally:
                os.close(parent)

        remove(relative)

    def rmdir_empty(self, relative: str) -> None:
        self.assert_anchor()
        descriptor = self.open_dir(relative)
        try:
            if os.listdir(descriptor):
                reject(f"directory is not an empty scaffold: {relative}", RECOVERY_REQUIRED)
            info = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        parent, name = self._parent(relative)
        try:
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                reject(f"empty scaffold identity changed: {relative}", RECOVERY_REQUIRED)
            self.assert_anchor()
            os.rmdir(name, dir_fd=parent)
            os.fsync(parent)
        finally:
            os.close(parent)


@dataclass
class Context:
    clean: CleanRoom
    tree: DirTree
    config: dict
    install_rel: str
    versions_rel: str
    transactions_rel: str
    receipt1_rel: str
    receipt2_rel: str

    def absolute(self, relative: str) -> str:
        return str(self.clean.session / relative)

    def relative(self, absolute: str, label: str) -> str:
        path = stable_host.require_canonical_absolute(Path(absolute), label, must_exist=False)
        try:
            relative = path.relative_to(self.clean.session).as_posix()
        except ValueError:
            reject(f"{label} escaped the clean-room session")
        safe_relative(relative)
        return relative


def make_context(session_root: str, home_root: str) -> Context:
    clean = validate_clean_room(session_root, home_root)
    try:
        tree = DirTree(clean.session_fd, clean.session)
        config = stable_host.load_config()
        stable_host.check_config_sync()
        install_rel = f"{clean.home_rel}/Library/Application Support/LinkDigest/NativeMessagingHost"
        return Context(
            clean=clean,
            tree=tree,
            config=config,
            install_rel=install_rel,
            versions_rel=f"{install_rel}/versions",
            transactions_rel=f"{install_rel}/{TRANSACTIONS}",
            receipt1_rel=f"{install_rel}/{RECEIPT_V1}",
            receipt2_rel=f"{install_rel}/{RECEIPT_V2}",
        )
    except BaseException:
        clean.close()
        raise


def close_context(context: Context) -> None:
    context.tree.close()
    context.clean.close()


TREE_KEYS = {"directories", "files", "packageDigest", "path", "version"}
DIRECTORY_KEYS = {"mode", "path"}
FILE_KEYS = {"hash", "mode", "path"}
MANIFEST_KEYS = {"hash", "mode", "path", "role"}
RECEIPT2_KEYS = {"current", "formatVersion", "hostName", "lineage", "ownedManifests"}
RECEIPT1_KEYS = {
    "formatVersion",
    "hostName",
    "installedVersion",
    "ownedManifests",
    "packageDigest",
    "versionDirectory",
}


def verified_package(package_root: str) -> stable_host.VerifiedPackage:
    path = Path(package_root)
    try:
        metadata = stable_host.load_json(path / stable_host.PACKAGE_METADATA)
        version = metadata.get("productVersion")
        if not isinstance(version, str) or not stable_host.SEMVER_RE.fullmatch(version):
            reject("package metadata productVersion must be a safe SemVer")
        package = stable_host.verify_package(path, expected_product_version=version)
    except stable_host.StableHostError as error:
        reject(str(error))
    ensure_semver(version, "package productVersion")
    return package


def version_key(version: str, config: dict) -> str:
    ensure_semver(version, "version")
    return f"{version}-macos-{config['architectures'][0]}"


def version_relative(context: Context, version: str) -> str:
    return f"{context.versions_rel}/{version_key(version, context.config)}"


def package_tree_record(package: stable_host.VerifiedPackage, context: Context) -> dict:
    directories, files = stable_host.walk_package(package.root)
    directory_records = [
        {
            "mode": "0700",
            "path": path.relative_to(package.root).as_posix() if path != package.root else ".",
        }
        for path in directories
    ]
    file_records = [
        {
            "hash": stable_host.sha256_file(path),
            "mode": "0755" if path.relative_to(package.root).as_posix() == package.config["entrypoint"] else "0600",
            "path": path.relative_to(package.root).as_posix(),
        }
        for path in files
    ]
    directory_records.sort(key=lambda item: os.fsencode(item["path"]))
    file_records.sort(key=lambda item: os.fsencode(item["path"]))
    version = package.metadata["productVersion"]
    return {
        "directories": directory_records,
        "files": file_records,
        "packageDigest": package.package_digest,
        "path": context.absolute(version_relative(context, version)),
        "version": version,
    }


def validate_tree_record(value: object, context: Context, label: str) -> dict:
    record = require_exact_keys(value, TREE_KEYS, label)
    version = ensure_semver(record["version"], f"{label}.version")
    package_digest = require_hash(record["packageDigest"], f"{label}.packageDigest")
    path = require_string(record["path"], f"{label}.path")
    expected_relative = version_relative(context, version)
    if context.relative(path, f"{label}.path") != expected_relative:
        reject(f"{label}.path is not the canonical version directory")
    directories = record["directories"]
    files = record["files"]
    if not isinstance(directories, list) or not directories or not isinstance(files, list) or not files:
        reject(f"{label} tree lists must be non-empty")
    seen_directories: set[str] = set()
    for index, item in enumerate(directories):
        item = require_exact_keys(item, DIRECTORY_KEYS, f"{label}.directories[{index}]")
        item_path = require_string(item["path"], f"{label}.directories[{index}].path")
        safe_relative(item_path, allow_dot=True)
        if require_mode(item["mode"], f"{label}.directories[{index}].mode") != "0700":
            reject(f"{label} directories must have mode 0700")
        if item_path in seen_directories:
            reject(f"{label} contains a duplicate directory")
        seen_directories.add(item_path)
    if seen_directories != {item["path"] for item in directories} or "." not in seen_directories:
        reject(f"{label} directory inventory is invalid")
    if [item["path"] for item in directories] != byte_sorted(seen_directories):
        reject(f"{label} directories are not canonically sorted")
    seen_files: set[str] = set()
    for index, item in enumerate(files):
        item = require_exact_keys(item, FILE_KEYS, f"{label}.files[{index}]")
        item_path = require_string(item["path"], f"{label}.files[{index}].path")
        safe_relative(item_path)
        require_hash(item["hash"], f"{label}.files[{index}].hash")
        item_mode = require_mode(item["mode"], f"{label}.files[{index}].mode")
        expected_mode = "0755" if item_path == context.config["entrypoint"] else "0600"
        if item_mode != expected_mode:
            reject(f"{label} file mode is not canonical: {item_path}")
        if item_path in seen_files:
            reject(f"{label} contains a duplicate file")
        seen_files.add(item_path)
    if [item["path"] for item in files] != byte_sorted(seen_files):
        reject(f"{label} files are not canonically sorted")
    if seen_files & (seen_directories - {"."}):
        reject(f"{label} uses a path as both file and directory")
    return {
        "directories": directories,
        "files": files,
        "packageDigest": package_digest,
        "path": path,
        "version": version,
    }


def _parse_installed_checksums(payload: bytes) -> dict[str, str]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        reject("installed SHA256SUMS is not UTF-8", OWNERSHIP_DRIFT)
    values: dict[str, str] = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            reject("installed SHA256SUMS is malformed", OWNERSHIP_DRIFT)
        digest, path = match.groups()
        safe_relative(path)
        if path in values:
            reject("installed SHA256SUMS contains a duplicate", OWNERSHIP_DRIFT)
        values[path] = digest
    canonical = "".join(f"{values[name]}  {name}\n" for name in byte_sorted(values)).encode("utf-8")
    if not values or payload != canonical:
        reject("installed SHA256SUMS is not canonical", OWNERSHIP_DRIFT)
    return values


def validate_installed_package(record: dict, context: Context, label: str) -> None:
    relative = context.relative(record["path"], f"{label}.path")
    context.tree.verify_tree(relative, record)
    files_by_path = {item["path"]: item for item in record["files"]}
    directories = {item["path"] for item in record["directories"]}
    expected_top = {
        stable_host.PACKAGE_METADATA,
        stable_host.CHECKSUMS,
        context.config["entrypoint"],
        context.config["resourceBundle"],
    }
    actual_top = {
        path.split("/", 1)[0]
        for path in (set(files_by_path) | (directories - {"."}))
    }
    if actual_top != expected_top:
        reject(f"{label} top-level package inventory drifted", OWNERSHIP_DRIFT)
    metadata_path = f"{relative}/{stable_host.PACKAGE_METADATA}"
    try:
        metadata = json.loads(context.tree.read_file(metadata_path, mode=0o600, limit=64 * 1024))
    except (UnicodeError, json.JSONDecodeError) as error:
        reject(f"{label} package metadata is invalid: {error}", OWNERSHIP_DRIFT)
    expected_metadata = stable_host.package_metadata(context.config)
    expected_metadata["productVersion"] = record["version"]
    if metadata != expected_metadata:
        reject(f"{label} package metadata drifted", OWNERSHIP_DRIFT)
    checksum_path = f"{relative}/{stable_host.CHECKSUMS}"
    checksum_payload = context.tree.read_file(checksum_path, mode=0o600, limit=16 * 1024 * 1024)
    if digest_bytes(checksum_payload) != record["packageDigest"]:
        reject(f"{label} package digest drifted", OWNERSHIP_DRIFT)
    checksums = _parse_installed_checksums(checksum_payload)
    expected_checksum_paths = byte_sorted(set(files_by_path) - {stable_host.CHECKSUMS})
    if list(checksums) != expected_checksum_paths:
        reject(f"{label} checksum coverage is not exact", OWNERSHIP_DRIFT)
    for path, expected_hash in checksums.items():
        if files_by_path[path]["hash"] != expected_hash:
            reject(f"{label} checksum disagrees with receipt: {path}", OWNERSHIP_DRIFT)
    schema_path = (
        f"{context.config['resourceBundle']}/Resources/contracts/"
        "capture-envelope-v1.schema.json"
    )
    schema = files_by_path.get(schema_path)
    if schema is None:
        reject(f"{label} contract schema is missing", OWNERSHIP_DRIFT)
    repository_schema = stable_host.sha256_file(
        stable_host.repository_root() / "contracts/capture-envelope-v1.schema.json"
    )
    if schema["hash"] != repository_schema:
        reject(f"{label} contract schema drifted", OWNERSHIP_DRIFT)


def paths_overlap(left: Path, right: Path) -> bool:
    try:
        left.relative_to(right)
        return True
    except ValueError:
        pass
    try:
        right.relative_to(left)
        return True
    except ValueError:
        return False


def manifest_role(context: Context, absolute: str, *, verify_profile: bool = True) -> tuple[str, str]:
    relative = context.relative(absolute, "manifest path")
    manifest_path = Path(absolute)
    install_path = Path(context.absolute(context.install_rel))
    if paths_overlap(manifest_path, install_path):
        reject(f"manifest target overlaps the transaction install namespace: {absolute}")
    filename = f"{context.config['hostName']}.json"
    chrome = (
        f"{context.clean.home_rel}/Library/Application Support/Google/Chrome/"
        f"NativeMessagingHosts/{filename}"
    )
    brave = (
        f"{context.clean.home_rel}/Library/Application Support/BraveSoftware/Brave-Browser/"
        f"NativeMessagingHosts/{filename}"
    )
    edge = (
        f"{context.clean.home_rel}/Library/Application Support/Microsoft Edge/"
        f"NativeMessagingHosts/{filename}"
    )
    if relative == chrome:
        return relative, "chrome-default"
    if relative == brave:
        return relative, "brave-default"
    if relative == edge:
        return relative, "edge-default"
    parts = safe_relative(relative)
    if len(parts) < 3 or parts[-2:] != ("NativeMessagingHosts", filename):
        reject(f"unknown manifest target: {absolute}")
    profile_relative = "/".join(parts[:-2])
    if profile_relative in {context.clean.home_rel, context.install_rel}:
        reject(f"unknown manifest target: {absolute}")
    if verify_profile:
        try:
            profile_fd = context.tree.open_dir(profile_relative)
        except FileNotFoundError:
            reject(f"manifest profile is missing: {absolute}", OWNERSHIP_DRIFT)
        else:
            os.close(profile_fd)
    if paths_overlap(Path(context.absolute(profile_relative)), install_path):
        reject(f"Edge profile overlaps the transaction install namespace: {absolute}")
    return relative, "edge-profile"


def validate_manifest_record(value: object, context: Context, label: str, *, verify: bool) -> dict:
    item = require_exact_keys(value, MANIFEST_KEYS, label)
    path = require_string(item["path"], f"{label}.path")
    relative, expected_role = manifest_role(context, path, verify_profile=verify)
    digest = require_hash(item["hash"], f"{label}.hash")
    if require_mode(item["mode"], f"{label}.mode") != "0600":
        reject(f"{label}.mode must be 0600")
    role = require_string(item["role"], f"{label}.role")
    if role != expected_role:
        reject(f"{label}.role does not match its target")
    if verify:
        if not context.tree.lexists(relative):
            reject(f"owned manifest is missing: {path}", OWNERSHIP_DRIFT)
        if context.tree.hash_file(relative, mode=0o600) != digest:
            reject(f"user-modified manifest: {path}", OWNERSHIP_DRIFT)
    return {"hash": digest, "mode": "0600", "path": path, "role": role}


@dataclass
class InstalledState:
    receipt_format: int
    receipt_rel: str
    receipt_hash: str
    receipt_bytes: bytes
    receipt_uid: int
    receipt_gid: int
    receipt_mode: int
    current: dict
    lineage: list[dict]
    manifests: list[dict]

    def receipt(self, host_name: str) -> dict:
        return {
            "current": self.current,
            "formatVersion": RECEIPT_FORMAT,
            "hostName": host_name,
            "lineage": self.lineage,
            "ownedManifests": self.manifests,
        }


def read_canonical_json(context: Context, relative: str, label: str) -> tuple[dict, bytes]:
    payload = context.tree.read_file(relative, mode=0o600, limit=16 * 1024 * 1024)
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        reject(f"{label} is invalid JSON: {error}", OWNERSHIP_DRIFT)
    if not isinstance(value, dict) or canonical_bytes(value) != payload:
        reject(f"{label} is not canonical JSON", OWNERSHIP_DRIFT)
    return value, payload


def read_receipt_v2(context: Context) -> InstalledState:
    receipt, payload = read_canonical_json(context, context.receipt2_rel, "receipt-v2")
    require_exact_keys(receipt, RECEIPT2_KEYS, "receipt-v2")
    if (
        type(receipt["formatVersion"]) is not int
        or receipt["formatVersion"] != RECEIPT_FORMAT
        or receipt["hostName"] != context.config["hostName"]
    ):
        reject("receipt-v2 identity is invalid", OWNERSHIP_DRIFT)
    current = validate_tree_record(receipt["current"], context, "receipt-v2.current")
    lineage_value = receipt["lineage"]
    manifest_value = receipt["ownedManifests"]
    if not isinstance(lineage_value, list) or not isinstance(manifest_value, list):
        reject("receipt-v2 lineage/manifests must be arrays")
    lineage = [
        validate_tree_record(item, context, f"receipt-v2.lineage[{index}]")
        for index, item in enumerate(lineage_value)
    ]
    all_versions = lineage + [current]
    paths = [item["path"] for item in all_versions]
    if len(paths) != len(set(paths)):
        reject("receipt-v2 contains duplicate version ownership")
    version_order = [semver_key(item["version"]) for item in all_versions]
    if any(left >= right for left, right in zip(version_order, version_order[1:])):
        reject("receipt-v2 lineage must be in strict upgrade order")
    manifests = [
        validate_manifest_record(item, context, f"receipt-v2.ownedManifests[{index}]", verify=True)
        for index, item in enumerate(manifest_value)
    ]
    manifest_paths = [item["path"] for item in manifests]
    if manifest_paths != byte_sorted(set(manifest_paths)):
        reject("receipt-v2 manifests are duplicate or not canonically sorted")
    for index, record in enumerate(all_versions):
        validate_installed_package(record, context, f"receipt-v2 version[{index}]")
    receipt_info = context.tree.lstat(context.receipt2_rel)
    return InstalledState(
        2,
        context.receipt2_rel,
        digest_bytes(payload),
        payload,
        receipt_info.st_uid,
        receipt_info.st_gid,
        stat.S_IMODE(receipt_info.st_mode),
        current,
        lineage,
        manifests,
    )


def read_receipt_v1(context: Context) -> InstalledState:
    receipt, payload = read_canonical_json(context, context.receipt1_rel, "receipt-v1")
    require_exact_keys(receipt, RECEIPT1_KEYS, "receipt-v1")
    if (
        type(receipt["formatVersion"]) is not int
        or receipt["formatVersion"] != 1
        or receipt["hostName"] != context.config["hostName"]
    ):
        reject("receipt-v1 identity is invalid", OWNERSHIP_DRIFT)
    installed_version = require_string(receipt["installedVersion"], "receipt-v1.installedVersion")
    suffix = f"-macos-{context.config['architectures'][0]}"
    if not installed_version.endswith(suffix):
        reject("receipt-v1 installedVersion is invalid")
    version = ensure_semver(installed_version[: -len(suffix)], "receipt-v1 installed version")
    package_digest = require_hash(receipt["packageDigest"], "receipt-v1.packageDigest")
    version_directory = require_string(receipt["versionDirectory"], "receipt-v1.versionDirectory")
    relative = context.relative(version_directory, "receipt-v1.versionDirectory")
    if relative != version_relative(context, version):
        reject("receipt-v1 versionDirectory is not canonical")
    if not context.tree.lexists(relative):
        reject("receipt-v1 owned version is missing", OWNERSHIP_DRIFT)
    directories, files = context.tree.snapshot_tree(relative)
    current = {
        "directories": directories,
        "files": files,
        "packageDigest": package_digest,
        "path": version_directory,
        "version": version,
    }
    validate_tree_record(current, context, "receipt-v1 current")
    validate_installed_package(current, context, "receipt-v1 current")
    owned = receipt["ownedManifests"]
    if not isinstance(owned, list) or not owned:
        reject("receipt-v1 ownedManifests must be non-empty")
    manifests: list[dict] = []
    seen: set[str] = set()
    for index, item_value in enumerate(owned):
        item = require_exact_keys(item_value, {"path", "sha256"}, f"receipt-v1.ownedManifests[{index}]")
        path = require_string(item["path"], f"receipt-v1.ownedManifests[{index}].path")
        relative, role = manifest_role(context, path)
        digest = require_hash(item["sha256"], f"receipt-v1.ownedManifests[{index}].sha256")
        if path in seen:
            reject("receipt-v1 contains duplicate manifest ownership")
        seen.add(path)
        if not context.tree.lexists(relative) or context.tree.hash_file(relative, mode=0o600) != digest:
            reject(f"receipt-v1 manifest is missing or user-modified: {path}", OWNERSHIP_DRIFT)
        manifests.append({"hash": digest, "mode": "0600", "path": path, "role": role})
    if [item["path"] for item in manifests] != byte_sorted(seen):
        reject("receipt-v1 manifests are not canonically sorted")
    manifests.sort(key=lambda item: os.fsencode(item["path"]))
    receipt_info = context.tree.lstat(context.receipt1_rel)
    return InstalledState(
        1,
        context.receipt1_rel,
        digest_bytes(payload),
        payload,
        receipt_info.st_uid,
        receipt_info.st_gid,
        stat.S_IMODE(receipt_info.st_mode),
        current,
        [],
        manifests,
    )


def read_state(context: Context) -> InstalledState | None:
    has_v1 = context.tree.lexists(context.receipt1_rel)
    has_v2 = context.tree.lexists(context.receipt2_rel)
    if has_v1 and has_v2:
        reject("both receipt-v1 and receipt-v2 exist without recovery", RECOVERY_REQUIRED)
    if has_v2:
        return read_receipt_v2(context)
    if has_v1:
        return read_receipt_v1(context)
    return None


def requested_manifests(
    context: Context,
    package: stable_host.VerifiedPackage,
    browsers: Sequence[str],
    extension_ids: Sequence[str],
    edge_profile_text: str | None,
) -> tuple[list[dict], dict[str, bytes]]:
    edge_profile = Path(edge_profile_text) if edge_profile_text else None
    try:
        targets = stable_host.manifest_targets(
            stable_host.CleanRoom(context.clean.session, context.clean.home),
            context.config,
            browsers,
            edge_profile,
        )
        host_path = Path(context.absolute(version_relative(context, package.metadata["productVersion"]))) / context.config["entrypoint"]
        payload = stable_host.render_manifest(context.config, host_path, "test", extension_ids)
    except stable_host.StableHostError as error:
        reject(str(error))
    install_path = Path(context.absolute(context.install_rel))
    if edge_profile is not None:
        profile_path = edge_profile
        if paths_overlap(profile_path, install_path):
            reject("Edge profile overlaps the transaction install namespace")
        if paths_overlap(profile_path, package.root):
            reject("Edge profile overlaps the verified package root")
    for target in targets:
        if paths_overlap(target, install_path):
            reject("manifest target overlaps the transaction install namespace")
        if paths_overlap(target, package.root):
            reject("manifest target overlaps the verified package root")
    records: list[dict] = []
    payloads: dict[str, bytes] = {}
    for target in targets:
        absolute = str(target)
        relative, role = manifest_role(context, absolute)
        payloads[absolute] = payload
        records.append({"hash": digest_bytes(payload), "mode": "0600", "path": absolute, "role": role})
        # Opening an existing parent here is read-only; missing parents are made
        # only after the plan is confirmed and journaled.
        parent = relative.rsplit("/", 1)[0]
        if context.tree.lexists(relative):
            context.tree.hash_file(relative, mode=0o600)
        else:
            try:
                descriptor = context.tree.open_dir(parent)
            except FileNotFoundError:
                pass
            else:
                os.close(descriptor)
    expected_roles: set[str] = set()
    requested = set(browsers)
    if "chrome" in requested:
        expected_roles.add("chrome-default")
    if "brave" in requested:
        expected_roles.add("brave-default")
    if "edge" in requested:
        expected_roles.add("edge-profile" if edge_profile is not None else "edge-default")
    if {record["role"] for record in records} != expected_roles:
        reject("browser manifest targets did not preserve independent requested roles")
    records.sort(key=lambda item: os.fsencode(item["path"]))
    return records, payloads


def state_plan_value(state: InstalledState | None) -> dict | None:
    if state is None:
        return None
    return {
        "current": state.current,
        "lineage": state.lineage,
        "ownedManifests": state.manifests,
        "receiptFormat": state.receipt_format,
        "receiptGid": state.receipt_gid,
        "receiptHash": state.receipt_hash,
        "receiptMode": mode_text(state.receipt_mode),
        "receiptPath": state.receipt_rel,
        "receiptUid": state.receipt_uid,
    }


def ensure_initial_namespace_is_empty(context: Context) -> None:
    if not context.tree.lexists(context.install_rel):
        return
    try:
        names = context.tree.listdir(context.install_rel)
    except (FileNotFoundError, NotADirectoryError):
        reject("install namespace is not a safe directory", OWNERSHIP_DRIFT)
    unknown = set(names) - {TRANSACTIONS, "versions"}
    if unknown:
        reject(f"unowned install namespace entries exist: {byte_sorted(unknown)}", OWNERSHIP_DRIFT)
    if "versions" in names and context.tree.listdir(context.versions_rel):
        reject("unowned version directories exist without a receipt", OWNERSHIP_DRIFT)


def receipt_v2(config: dict, current: dict, lineage: list[dict], manifests: list[dict]) -> dict:
    return {
        "current": current,
        "formatVersion": RECEIPT_FORMAT,
        "hostName": config["hostName"],
        "lineage": lineage,
        "ownedManifests": manifests,
    }


def compute_plan(args: argparse.Namespace, context: Context) -> dict:
    active = active_journals(context)
    if active:
        reject("an unfinished transaction requires recover", ACTIVE_TRANSACTION)
    state = read_state(context)
    action = args.action
    package: stable_host.VerifiedPackage | None = None
    package_record: dict | None = None
    manifests: list[dict] = []
    manifest_payloads: dict[str, bytes] = {}
    if action in {"install", "upgrade"}:
        if not args.package_root:
            reject(f"--package-root is required for {action}")
        package = verified_package(args.package_root)
        package_record = package_tree_record(package, context)
        manifests, manifest_payloads = requested_manifests(
            context,
            package,
            args.browser,
            args.extension_id,
            args.edge_user_data_dir,
        )
    elif args.package_root or args.browser or args.extension_id or args.edge_user_data_dir:
        reject("uninstall does not accept package, browser, extension, or Edge profile inputs")

    operation: str
    after_receipt: dict | None = None
    publish_version: dict | None = None
    remove_versions: list[dict] = []
    if action == "install":
        assert package_record is not None
        if state is None:
            ensure_initial_namespace_is_empty(context)
            if context.tree.lexists(context.relative(package_record["path"], "package version path")):
                reject("initial version target already exists without ownership", OWNERSHIP_DRIFT)
            for manifest in manifests:
                if context.tree.lexists(context.relative(manifest["path"], "manifest path")):
                    reject(f"manifest target already exists without ownership: {manifest['path']}", OWNERSHIP_DRIFT)
            operation = "initial-install"
            publish_version = package_record
            after_receipt = receipt_v2(context.config, package_record, [], manifests)
        else:
            same_package = (
                state.current["version"] == package_record["version"]
                and state.current["packageDigest"] == package_record["packageDigest"]
                and state.current["directories"] == package_record["directories"]
                and state.current["files"] == package_record["files"]
            )
            if not same_package:
                reject("install cannot replace an existing package; use --action upgrade")
            existing_paths = {item["path"] for item in state.manifests}
            for manifest in manifests:
                relative = context.relative(manifest["path"], "manifest path")
                if manifest["path"] not in existing_paths and context.tree.lexists(relative):
                    reject(f"new manifest target is already unowned: {manifest['path']}", OWNERSHIP_DRIFT)
            if state.receipt_format == 2 and state.manifests == manifests:
                operation = "noop"
                after_receipt = state.receipt(context.config["hostName"])
            else:
                operation = "migrate-v1" if state.receipt_format == 1 else "manifest-reconcile"
                after_receipt = receipt_v2(context.config, state.current, state.lineage, manifests)
    elif action == "upgrade":
        assert package_record is not None
        if state is None:
            reject("upgrade requires an owned existing receipt", OWNERSHIP_DRIFT)
        existing_paths = {item["path"] for item in state.manifests}
        for manifest in manifests:
            relative = context.relative(manifest["path"], "manifest path")
            if manifest["path"] not in existing_paths and context.tree.lexists(relative):
                reject(f"new manifest target is already unowned: {manifest['path']}", OWNERSHIP_DRIFT)
        same_package = (
            state.current["version"] == package_record["version"]
            and state.current["packageDigest"] == package_record["packageDigest"]
            and state.current["directories"] == package_record["directories"]
            and state.current["files"] == package_record["files"]
        )
        if same_package:
            if state.receipt_format == 2 and state.manifests == manifests:
                operation = "noop"
                after_receipt = state.receipt(context.config["hostName"])
            else:
                operation = "migrate-v1" if state.receipt_format == 1 else "manifest-reconcile"
                after_receipt = receipt_v2(context.config, state.current, state.lineage, manifests)
        else:
            if package_record["version"] == state.current["version"]:
                reject("upgrade package reuses the current version with different content", OWNERSHIP_DRIFT)
            if semver_key(package_record["version"]) <= semver_key(state.current["version"]):
                reject("upgrade package version must be strictly newer")
            new_relative = context.relative(package_record["path"], "upgrade version path")
            if context.tree.lexists(new_relative):
                reject("upgrade version target already exists without current receipt ownership", OWNERSHIP_DRIFT)
            operation = "upgrade"
            publish_version = package_record
            lineage = state.lineage + [state.current]
            after_receipt = receipt_v2(context.config, package_record, lineage, manifests)
    elif action == "uninstall":
        if state is None:
            ensure_initial_namespace_is_empty(context)
            operation = "noop"
        else:
            operation = "uninstall"
            remove_versions = state.lineage + [state.current]
    else:
        reject(f"unsupported action: {action}")

    body = {
        "action": action,
        "afterReceipt": after_receipt,
        "before": state_plan_value(state),
        "formatVersion": PLAN_FORMAT,
        "homeRoot": str(context.clean.home),
        "manifestPayloads": [
            {"base64": base64.b64encode(payload).decode("ascii"), "path": path}
            for path, payload in sorted(manifest_payloads.items(), key=lambda item: os.fsencode(item[0]))
        ],
        "operation": operation,
        "packageRoot": str(package.root) if package is not None else None,
        "publishVersion": publish_version,
        "removeVersions": remove_versions,
        "sessionRoot": str(context.clean.session),
    }
    plan_digest = digest_bytes(canonical_bytes(body))
    return body | {
        "confirmation": f"{action}:{plan_digest}",
        "planDigest": plan_digest,
    }


def plan_body(plan: dict) -> dict:
    return {key: value for key, value in plan.items() if key not in {"confirmation", "planDigest"}}


def acquire_lock(context: Context, test_barriers: bool) -> int:
    parent, name = context.tree._parent(LOCK_NAME)
    descriptor: int | None = None
    try:
        descriptor = os.open(name, os.O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, dir_fd=parent)
        DirTree._validate_file_info(os.fstat(descriptor), LOCK_NAME, 0o600)
        if DirTree._read_descriptor(descriptor) != LOCK_CONTENT:
            reject("transaction lock content changed")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            reject("another transaction holds the permanent lock", LOCK_BUSY)
        run_barrier("lock_acquired", context, test_barriers)
        return descriptor
    except BaseException:
        if descriptor is not None:
            os.close(descriptor)
        raise
    finally:
        os.close(parent)


def run_barrier(name: str, context: Context, enabled: bool) -> None:
    if not enabled:
        return
    if not str(context.clean.session).startswith("/private/tmp/"):
        reject("test barriers require a /private/tmp session")
    selected = {item for item in os.environ.get("LINKDIGEST_TEST_BARRIER", "").split(",") if item}
    if name not in selected:
        return
    fd_text = os.environ.get("LINKDIGEST_TEST_BARRIER_FD")
    if fd_text:
        try:
            os.write(int(fd_text), f"{name}\n".encode("ascii"))
        except (OSError, ValueError) as error:
            raise BarrierError(f"test barrier FD failed at {name}: {error}") from error
    action = os.environ.get("LINKDIGEST_TEST_BARRIER_ACTION", "error")
    if action == "error":
        raise BarrierError(f"test barrier stopped at {name}")
    if action == "sigkill":
        os.kill(os.getpid(), 9)
    if action == "continue":
        return
    if action == "wait":
        release_fd = os.environ.get("LINKDIGEST_TEST_RELEASE_FD")
        if not release_fd:
            raise BarrierError("wait barrier requires LINKDIGEST_TEST_RELEASE_FD")
        try:
            if os.read(int(release_fd), 1) != b"1":
                raise BarrierError(f"test barrier release failed at {name}")
        except (OSError, ValueError) as error:
            raise BarrierError(f"test barrier release FD failed at {name}: {error}") from error
        return
    raise BarrierError(f"unknown test barrier action: {action}")


JOURNAL_KEYS = {"formatVersion", "phase", "plan", "txid"}
TERMINAL_PHASES = {"complete", "rolled-back"}
PLAN_KEYS = {
    "action",
    "afterReceipt",
    "before",
    "formatVersion",
    "homeRoot",
    "manifestPayloads",
    "operation",
    "packageRoot",
    "publishVersion",
    "removeVersions",
    "sessionRoot",
}
BEFORE_KEYS = {
    "current",
    "lineage",
    "ownedManifests",
    "receiptFormat",
    "receiptGid",
    "receiptHash",
    "receiptMode",
    "receiptPath",
    "receiptUid",
}
VALID_OPERATIONS = {
    "install": {"initial-install", "manifest-reconcile", "migrate-v1", "noop"},
    "upgrade": {"manifest-reconcile", "migrate-v1", "noop", "upgrade"},
    "uninstall": {"noop", "uninstall"},
}


def validate_receipt_structure(value: object, context: Context, label: str) -> dict:
    receipt = require_exact_keys(value, RECEIPT2_KEYS, label)
    if (
        type(receipt["formatVersion"]) is not int
        or receipt["formatVersion"] != RECEIPT_FORMAT
        or receipt["hostName"] != context.config["hostName"]
    ):
        reject(f"{label} identity is invalid")
    current = validate_tree_record(receipt["current"], context, f"{label}.current")
    lineage_value = receipt["lineage"]
    manifests_value = receipt["ownedManifests"]
    if not isinstance(lineage_value, list) or not isinstance(manifests_value, list):
        reject(f"{label} lineage/manifests must be arrays")
    lineage = [
        validate_tree_record(item, context, f"{label}.lineage[{index}]")
        for index, item in enumerate(lineage_value)
    ]
    versions = lineage + [current]
    if len({item["path"] for item in versions}) != len(versions):
        reject(f"{label} contains duplicate version ownership")
    order = [semver_key(item["version"]) for item in versions]
    if any(left >= right for left, right in zip(order, order[1:])):
        reject(f"{label} lineage is not in strict upgrade order")
    manifests = [
        validate_manifest_record(item, context, f"{label}.ownedManifests[{index}]", verify=False)
        for index, item in enumerate(manifests_value)
    ]
    manifest_paths = [item["path"] for item in manifests]
    if manifest_paths != byte_sorted(set(manifest_paths)):
        reject(f"{label} manifests are duplicate or not canonically sorted")
    return receipt


def validate_before_structure(value: object, context: Context) -> dict:
    before = require_exact_keys(value, BEFORE_KEYS, "journal.plan.before")
    receipt_format = before["receiptFormat"]
    if type(receipt_format) is not int or receipt_format not in {1, 2}:
        reject("journal.plan.before receiptFormat is invalid")
    for key in ("receiptUid", "receiptGid"):
        if type(before[key]) is not int or before[key] < 0:
            reject(f"journal.plan.before {key} is invalid")
    if before["receiptMode"] != "0600":
        reject("journal.plan.before receiptMode is invalid")
    require_hash(before["receiptHash"], "journal.plan.before.receiptHash")
    expected_receipt = context.receipt1_rel if receipt_format == 1 else context.receipt2_rel
    if before["receiptPath"] != expected_receipt:
        reject("journal.plan.before receiptPath does not match receiptFormat")
    current = validate_tree_record(before["current"], context, "journal.plan.before.current")
    lineage_value = before["lineage"]
    manifests_value = before["ownedManifests"]
    if not isinstance(lineage_value, list) or not isinstance(manifests_value, list):
        reject("journal.plan.before lineage/manifests must be arrays")
    lineage = [
        validate_tree_record(item, context, f"journal.plan.before.lineage[{index}]")
        for index, item in enumerate(lineage_value)
    ]
    versions = lineage + [current]
    if len({item["path"] for item in versions}) != len(versions):
        reject("journal.plan.before contains duplicate version ownership")
    order = [semver_key(item["version"]) for item in versions]
    if any(left >= right for left, right in zip(order, order[1:])):
        reject("journal.plan.before lineage is not in strict upgrade order")
    manifests = [
        validate_manifest_record(item, context, f"journal.plan.before.ownedManifests[{index}]", verify=False)
        for index, item in enumerate(manifests_value)
    ]
    paths = [item["path"] for item in manifests]
    if paths != byte_sorted(set(paths)):
        reject("journal.plan.before manifests are duplicate or not sorted")
    return before


def validate_payload_structure(value: object, after: dict | None) -> None:
    if not isinstance(value, list):
        reject("journal.plan manifestPayloads must be an array")
    payloads: dict[str, bytes] = {}
    ordered_paths: list[str] = []
    for index, item_value in enumerate(value):
        item = require_exact_keys(item_value, {"base64", "path"}, f"journal.plan.manifestPayloads[{index}]")
        path = require_string(item["path"], f"journal.plan.manifestPayloads[{index}].path")
        try:
            payload = base64.b64decode(require_string(item["base64"], "journal manifest base64"), validate=True)
        except (ValueError, base64.binascii.Error) as error:
            reject(f"journal manifest payload is invalid base64: {error}")
        if path in payloads:
            reject("journal manifest payload paths are duplicated")
        payloads[path] = payload
        ordered_paths.append(path)
    if ordered_paths != byte_sorted(payloads):
        reject("journal manifest payloads are not canonically sorted")
    expected = {} if after is None else {item["path"]: item for item in after["ownedManifests"]}
    if set(payloads) != set(expected):
        reject("journal manifest payload coverage differs from afterReceipt")
    for path, payload in payloads.items():
        if digest_bytes(payload) != expected[path]["hash"]:
            reject("journal manifest payload hash differs from afterReceipt")


def validate_journal_plan(value: object, context: Context) -> dict:
    plan = require_exact_keys(value, PLAN_KEYS, "journal.plan")
    if type(plan["formatVersion"]) is not int or plan["formatVersion"] != PLAN_FORMAT:
        reject("journal.plan formatVersion is invalid")
    if plan["sessionRoot"] != str(context.clean.session) or plan["homeRoot"] != str(context.clean.home):
        reject("journal.plan roots do not match the active clean-room")
    action = plan["action"]
    operation = plan["operation"]
    if not isinstance(action, str) or action not in VALID_OPERATIONS:
        reject("journal.plan action is invalid")
    if not isinstance(operation, str) or operation not in VALID_OPERATIONS[action]:
        reject("journal.plan action/operation relationship is invalid")

    before = None if plan["before"] is None else validate_before_structure(plan["before"], context)
    after = None if plan["afterReceipt"] is None else validate_receipt_structure(
        plan["afterReceipt"], context, "journal.plan.afterReceipt"
    )
    publish = None if plan["publishVersion"] is None else validate_tree_record(
        plan["publishVersion"], context, "journal.plan.publishVersion"
    )
    remove_value = plan["removeVersions"]
    if not isinstance(remove_value, list):
        reject("journal.plan removeVersions must be an array")
    remove = [
        validate_tree_record(item, context, f"journal.plan.removeVersions[{index}]")
        for index, item in enumerate(remove_value)
    ]

    if action in {"install", "upgrade"}:
        package_root = require_string(plan["packageRoot"], "journal.plan.packageRoot")
        stable_host.require_canonical_absolute(Path(package_root), "journal.plan.packageRoot", must_exist=False)
        if after is None:
            reject("install/upgrade journal requires afterReceipt")
        package_path = Path(package_root)
        for manifest in after["ownedManifests"]:
            target = Path(manifest["path"])
            if paths_overlap(target, package_path):
                reject("journal manifest target overlaps packageRoot")
            if manifest["role"] == "edge-profile" and paths_overlap(target.parent.parent, package_path):
                reject("journal Edge profile overlaps packageRoot")
    elif plan["packageRoot"] is not None or after is not None:
        reject("uninstall journal cannot own packageRoot/afterReceipt")

    if operation == "initial-install":
        if action != "install" or before is not None or publish is None or remove:
            reject("initial-install journal ownership relationship is invalid")
        if after["current"] != publish or after["lineage"]:
            reject("initial-install afterReceipt does not match published version")
    elif operation == "upgrade":
        if action != "upgrade" or before is None or publish is None or remove:
            reject("upgrade journal ownership relationship is invalid")
        if after["current"] != publish or after["lineage"] != before["lineage"] + [before["current"]]:
            reject("upgrade afterReceipt lineage/current relationship is invalid")
    elif operation in {"manifest-reconcile", "migrate-v1", "noop"} and action in {"install", "upgrade"}:
        if before is None or publish is not None or remove:
            reject("reconcile/migrate/noop journal ownership relationship is invalid")
        if after["current"] != before["current"] or after["lineage"] != before["lineage"]:
            reject("reconcile/migrate/noop afterReceipt changed version ownership")
        if operation == "migrate-v1" and before["receiptFormat"] != 1:
            reject("migrate-v1 journal does not start from receipt-v1")
    elif operation == "uninstall":
        if before is None or publish is not None or remove != before["lineage"] + [before["current"]]:
            reject("uninstall journal ownership relationship is invalid")
    elif operation == "noop" and action == "uninstall":
        if before is not None or publish is not None or remove:
            reject("uninstall noop journal is not empty")
    else:
        reject("journal action/operation relationship is unsupported")

    validate_payload_structure(plan["manifestPayloads"], after)
    return plan


def journal_relative(context: Context, txid: str) -> str:
    if not SAFE_TXID_RE.fullmatch(txid):
        reject("transaction id is unsafe", RECOVERY_REQUIRED)
    return f"{context.transactions_rel}/{txid}/{JOURNAL}"


def read_journal(context: Context, txid: str) -> dict:
    try:
        value, _ = read_canonical_json(context, journal_relative(context, txid), f"transaction {txid} journal")
        require_exact_keys(value, JOURNAL_KEYS, "journal")
        if type(value["formatVersion"]) is not int or value["formatVersion"] != JOURNAL_FORMAT or value["txid"] != txid:
            reject("journal identity is invalid")
        phase = value["phase"]
        if not isinstance(phase, str) or not (
            phase in {"complete", "prepared", "receipt-backed-up", "receipt-committed", "rolled-back", "version-published"}
            or re.fullmatch(r"(?:manifest-backed-up|manifest-published|version-backed-up)-[0-9]{4}", phase)
        ):
            reject("journal phase is invalid")
        validate_journal_plan(value["plan"], context)
        return value
    except TransactionError as error:
        raise TransactionError(RECOVERY_REQUIRED, f"malformed transaction journal {txid}: {error}") from error
    except stable_host.StableHostError as error:
        raise TransactionError(RECOVERY_REQUIRED, f"malformed transaction journal {txid}: {error}") from error
    except (KeyError, TypeError, ValueError, IndexError) as error:
        raise TransactionError(RECOVERY_REQUIRED, f"malformed transaction journal {txid}: {error}") from error


def _validate_scaffold(context: Context, txid: str) -> None:
    root = f"{context.transactions_rel}/{txid}"
    names = context.tree.listdir(root)
    if set(names) - {"backups", "staged"}:
        reject(f"journal-less transaction {txid} contains unknown entries", RECOVERY_REQUIRED)
    if "staged" in names and context.tree.listdir(f"{root}/staged"):
        reject(f"journal-less transaction {txid} has non-empty staged data", RECOVERY_REQUIRED)
    if "backups" in names:
        backup_names = context.tree.listdir(f"{root}/backups")
        if set(backup_names) - {"manifests", "versions"}:
            reject(f"journal-less transaction {txid} has unknown backups", RECOVERY_REQUIRED)
        for name in backup_names:
            if context.tree.listdir(f"{root}/backups/{name}"):
                reject(f"journal-less transaction {txid} has non-empty backups", RECOVERY_REQUIRED)


def scan_transactions(context: Context) -> tuple[list[tuple[str, dict]], list[str]]:
    if not context.tree.lexists(context.transactions_rel):
        return [], []
    try:
        names = context.tree.listdir(context.transactions_rel)
    except (FileNotFoundError, NotADirectoryError):
        reject("transactions namespace is unsafe", RECOVERY_REQUIRED)
    active: list[tuple[str, dict]] = []
    scaffolds: list[str] = []
    for name in names:
        if not SAFE_TXID_RE.fullmatch(name):
            reject(f"unknown entry in transactions namespace: {name}", RECOVERY_REQUIRED)
        transaction_rel = f"{context.transactions_rel}/{name}"
        try:
            descriptor = context.tree.open_dir(transaction_rel)
        except (OSError, TransactionError) as error:
            reject(f"transaction entry is not a safe directory: {name}: {error}", RECOVERY_REQUIRED)
        else:
            os.close(descriptor)
        if not context.tree.lexists(journal_relative(context, name)):
            _validate_scaffold(context, name)
            scaffolds.append(name)
            continue
        try:
            journal = read_journal(context, name)
        except TransactionError as error:
            reject(f"transaction journal is unsafe: {name}: {error}", RECOVERY_REQUIRED)
        if journal["phase"] not in TERMINAL_PHASES:
            active.append((name, journal))
    if len(active) > 1:
        reject("multiple active transactions require manual review", RECOVERY_REQUIRED)
    return active, scaffolds


def active_journals(context: Context) -> list[tuple[str, dict]]:
    active, scaffolds = scan_transactions(context)
    if scaffolds:
        reject("a journal-less transaction scaffold requires recover", ACTIVE_TRANSACTION)
    return active


def recover_scaffold(context: Context, txid: str) -> None:
    _validate_scaffold(context, txid)
    root = f"{context.transactions_rel}/{txid}"
    if context.tree.lexists(f"{root}/backups"):
        for child in ("manifests", "versions"):
            relative = f"{root}/backups/{child}"
            if context.tree.lexists(relative):
                context.tree.rmdir_empty(relative)
        context.tree.rmdir_empty(f"{root}/backups")
    if context.tree.lexists(f"{root}/staged"):
        context.tree.rmdir_empty(f"{root}/staged")
    context.tree.rmdir_empty(root)


def write_journal(context: Context, journal: dict) -> None:
    txid = journal["txid"]
    relative = journal_relative(context, txid)
    if context.tree.lexists(relative):
        current_hash = context.tree.hash_file(relative, mode=0o600)
        context.tree.write_atomic(
            relative,
            canonical_bytes(journal),
            0o600,
            txid,
            expected_existing_hash=current_hash,
        )
    else:
        context.tree.write_exclusive(relative, canonical_bytes(journal), 0o600)


def update_phase(context: Context, journal: dict, phase: str) -> None:
    journal["phase"] = phase
    write_journal(context, journal)


def tx_relative(context: Context, txid: str, suffix: str) -> str:
    safe_relative(suffix)
    return f"{context.transactions_rel}/{txid}/{suffix}"


def manifest_backup(context: Context, txid: str, index: int) -> str:
    return tx_relative(context, txid, f"backups/manifests/{index:04d}.json")


def version_backup(context: Context, txid: str, index: int) -> str:
    return tx_relative(context, txid, f"backups/versions/{index:04d}")


def receipt_backup(context: Context, txid: str) -> str:
    return tx_relative(context, txid, "backups/receipt.json")


def staged_version(context: Context, txid: str) -> str:
    return tx_relative(context, txid, "staged/version")


def payload_map(plan: dict) -> dict[str, bytes]:
    values = plan.get("manifestPayloads")
    if not isinstance(values, list):
        reject("journal manifest payloads are invalid", RECOVERY_REQUIRED)
    result: dict[str, bytes] = {}
    for index, item_value in enumerate(values):
        item = require_exact_keys(item_value, {"base64", "path"}, f"manifestPayloads[{index}]")
        path = require_string(item["path"], f"manifestPayloads[{index}].path")
        try:
            payload = base64.b64decode(require_string(item["base64"], "manifest base64"), validate=True)
        except (ValueError, base64.binascii.Error) as error:
            reject(f"manifest payload is not valid base64: {error}", RECOVERY_REQUIRED)
        if path in result:
            reject("duplicate manifest payload path", RECOVERY_REQUIRED)
        result[path] = payload
    return result


def expected_after_manifest_map(plan: dict) -> dict[str, dict]:
    receipt = plan.get("afterReceipt")
    if receipt is None:
        return {}
    if not isinstance(receipt, dict) or not isinstance(receipt.get("ownedManifests"), list):
        reject("journal afterReceipt is invalid", RECOVERY_REQUIRED)
    return {item["path"]: item for item in receipt["ownedManifests"]}


def begin_journal(context: Context, plan: dict) -> dict:
    txid = uuid.uuid4().hex
    context.tree.ensure_dir(f"{context.transactions_rel}/{txid}")
    journal = {
        "formatVersion": JOURNAL_FORMAT,
        "phase": "prepared",
        "plan": plan_body(plan),
        "txid": txid,
    }
    write_journal(context, journal)
    return journal


def prepare_transaction_directories(context: Context, txid: str) -> None:
    context.tree.ensure_dir(f"{context.transactions_rel}/{txid}/staged")
    context.tree.ensure_dir(f"{context.transactions_rel}/{txid}/backups/manifests")
    context.tree.ensure_dir(f"{context.transactions_rel}/{txid}/backups/versions")


def backup_receipt(context: Context, journal: dict) -> None:
    before = journal["plan"]["before"]
    if before is None:
        return
    backup = receipt_backup(context, journal["txid"])
    expected_mode = int(before["receiptMode"], 8)

    def verify_metadata(relative: str) -> None:
        info = context.tree.lstat(relative)
        if (
            info.st_uid != before["receiptUid"]
            or info.st_gid != before["receiptGid"]
            or stat.S_IMODE(info.st_mode) != expected_mode
            or info.st_nlink != 1
        ):
            reject("transaction receipt metadata drifted", RECOVERY_REQUIRED)

    if context.tree.lexists(backup):
        verify_metadata(backup)
        if context.tree.hash_file(backup, mode=expected_mode) != before["receiptHash"]:
            reject("transaction receipt backup drifted", RECOVERY_REQUIRED)
        return
    verify_metadata(before["receiptPath"])
    context.tree.copy_file_preserve(before["receiptPath"], backup)
    verify_metadata(backup)
    if context.tree.hash_file(backup, mode=expected_mode) != before["receiptHash"]:
        reject("transaction receipt backup failed verification", RECOVERY_REQUIRED)


def backup_manifests(context: Context, journal: dict) -> None:
    before = journal["plan"]["before"]
    if before is None:
        return
    for index, manifest in enumerate(before["ownedManifests"]):
        source = context.relative(manifest["path"], "owned manifest")
        backup = manifest_backup(context, journal["txid"], index)
        if context.tree.lexists(backup):
            if context.tree.hash_file(backup, mode=0o600) != manifest["hash"]:
                reject("manifest backup drifted", RECOVERY_REQUIRED)
        elif context.tree.lexists(source):
            if context.tree.hash_file(source, mode=0o600) != manifest["hash"]:
                reject(f"user-modified manifest: {manifest['path']}", OWNERSHIP_DRIFT)
            context.tree.rename(source, backup, create_destination_parent=True)
        else:
            reject(f"owned manifest disappeared during apply: {manifest['path']}", OWNERSHIP_DRIFT)
        update_phase(context, journal, f"manifest-backed-up-{index:04d}")


def publish_manifests(context: Context, journal: dict) -> None:
    plan = journal["plan"]
    payloads = payload_map(plan)
    expected = expected_after_manifest_map(plan)
    if set(payloads) != set(expected):
        reject("manifest payload coverage differs from afterReceipt", RECOVERY_REQUIRED)
    for index, path in enumerate(byte_sorted(payloads)):
        payload = payloads[path]
        if digest_bytes(payload) != expected[path]["hash"]:
            reject("manifest payload hash differs from afterReceipt", RECOVERY_REQUIRED)
        relative = context.relative(path, "manifest publish target")
        if context.tree.lexists(relative):
            reject(f"manifest target appeared during apply: {path}", OWNERSHIP_DRIFT)
        context.tree.write_exclusive(relative, payload, 0o600)
        update_phase(context, journal, f"manifest-published-{index:04d}")


def publish_version(context: Context, journal: dict) -> None:
    plan = journal["plan"]
    record = plan["publishVersion"]
    if record is None:
        return
    package_root = plan["packageRoot"]
    if not isinstance(package_root, str):
        reject("journal packageRoot is missing", RECOVERY_REQUIRED)
    package = verified_package(package_root)
    expected = package_tree_record(package, context)
    if expected != record:
        reject("package changed after plan confirmation", STALE_PLAN)
    staged = staged_version(context, journal["txid"])
    context.tree.copy_package_tree(package.root, staged, context.config["entrypoint"])
    context.tree.verify_tree(staged, record)
    # Verify the source one more time after staging.  Together with the staged
    # tree comparison this closes package mutation during the copy window.
    if package_tree_record(verified_package(package_root), context) != record:
        reject("package changed while it was staged", STALE_PLAN)
    destination = context.relative(record["path"], "published version")
    if context.tree.lexists(destination):
        reject("published version target appeared during apply", OWNERSHIP_DRIFT)
    context.tree.rename(staged, destination, create_destination_parent=True)
    validate_installed_package(record, context, "published version")
    update_phase(context, journal, "version-published")


def move_uninstall_versions(context: Context, journal: dict) -> None:
    for index, record in enumerate(journal["plan"]["removeVersions"]):
        source = context.relative(record["path"], "uninstall version")
        context.tree.verify_tree(source, record)
        backup = version_backup(context, journal["txid"], index)
        if context.tree.lexists(backup):
            reject("uninstall version backup unexpectedly exists", RECOVERY_REQUIRED)
        context.tree.rename(source, backup, create_destination_parent=True)
        context.tree.verify_tree(backup, record)
        update_phase(context, journal, f"version-backed-up-{index:04d}")


def commit_receipt(context: Context, journal: dict, test_barriers: bool) -> None:
    plan = journal["plan"]
    before = plan["before"]
    run_barrier("before_receipt_commit", context, test_barriers)
    if plan["operation"] == "uninstall":
        if before is None:
            reject("uninstall journal lost its before receipt", RECOVERY_REQUIRED)
        context.tree.unlink_file(
            before["receiptPath"],
            expected_hash=before["receiptHash"],
            mode=0o600,
        )
    else:
        after = plan["afterReceipt"]
        if after is None:
            reject("install/upgrade journal lost afterReceipt", RECOVERY_REQUIRED)
        payload = canonical_bytes(after)
        if before is not None and before["receiptFormat"] == 2:
            context.tree.write_atomic(
                context.receipt2_rel,
                payload,
                0o600,
                journal["txid"],
                expected_existing_hash=before["receiptHash"],
            )
        else:
            if context.tree.lexists(context.receipt2_rel):
                reject("receipt-v2 appeared before commit", OWNERSHIP_DRIFT)
            context.tree.write_exclusive(context.receipt2_rel, payload, 0o600)
    run_barrier("after_receipt_commit", context, test_barriers)
    update_phase(context, journal, "receipt-committed")


def receipt_commit_state(context: Context, plan: dict) -> bool:
    before = plan["before"]
    if plan["operation"] == "uninstall":
        if before is None:
            reject("uninstall journal has no before receipt", RECOVERY_REQUIRED)
        if context.tree.lexists(before["receiptPath"]):
            digest = context.tree.hash_file(before["receiptPath"], mode=0o600)
            if digest == before["receiptHash"]:
                return False
            reject("live receipt changed during uninstall recovery", RECOVERY_REQUIRED)
        return True
    after = plan["afterReceipt"]
    if after is None:
        reject("journal has no after receipt", RECOVERY_REQUIRED)
    expected_after = digest_bytes(canonical_bytes(after))
    if context.tree.lexists(context.receipt2_rel):
        live = context.tree.hash_file(context.receipt2_rel, mode=0o600)
        if live == expected_after:
            return True
        if before is not None and before["receiptFormat"] == 2 and live == before["receiptHash"]:
            return False
        reject("live receipt-v2 is neither pre-commit nor committed state", RECOVERY_REQUIRED)
    if before is not None and before["receiptFormat"] == 2:
        reject("pre-commit receipt-v2 disappeared", RECOVERY_REQUIRED)
    return False


def remove_exact_if_present(context: Context, relative: str, expected_hash: str, mode: int = 0o600) -> None:
    if context.tree.lexists(relative):
        context.tree.unlink_file(relative, expected_hash=expected_hash, mode=mode)


def finalize_transaction(context: Context, journal: dict) -> str:
    plan = journal["plan"]
    txid = journal["txid"]
    before = plan["before"]
    if plan["operation"] == "uninstall":
        if before is None:
            reject("uninstall finalize has no ownership receipt", RECOVERY_REQUIRED)
        for index, manifest in enumerate(before["ownedManifests"]):
            remove_exact_if_present(context, manifest_backup(context, txid, index), manifest["hash"])
        for index, record in enumerate(plan["removeVersions"]):
            backup = version_backup(context, txid, index)
            if context.tree.lexists(backup):
                context.tree.remove_tree(backup, record)
        remove_exact_if_present(context, receipt_backup(context, txid), before["receiptHash"])
    else:
        # Strict read verifies receipt, current/lineage trees, and all manifests.
        state = read_receipt_v2(context)
        if state.receipt(context.config["hostName"]) != plan["afterReceipt"]:
            reject("committed receipt differs from journal afterReceipt", RECOVERY_REQUIRED)
        if before is not None:
            for index, manifest in enumerate(before["ownedManifests"]):
                remove_exact_if_present(context, manifest_backup(context, txid, index), manifest["hash"])
            remove_exact_if_present(context, receipt_backup(context, txid), before["receiptHash"])
            if before["receiptFormat"] == 1 and context.tree.lexists(context.receipt1_rel):
                context.tree.unlink_file(
                    context.receipt1_rel,
                    expected_hash=before["receiptHash"],
                    mode=0o600,
                )
    staged = staged_version(context, txid)
    if context.tree.lexists(staged):
        context.tree.remove_tree(staged)
    update_phase(context, journal, "complete")
    return "finalized"


def restore_manifest_backups(context: Context, journal: dict) -> None:
    plan = journal["plan"]
    before = plan["before"]
    after = expected_after_manifest_map(plan)
    if before is None:
        before_manifests: list[dict] = []
    else:
        before_manifests = before["ownedManifests"]
    before_by_path = {item["path"]: item for item in before_manifests}
    for path, manifest in after.items():
        relative = context.relative(path, "rollback manifest")
        if not context.tree.lexists(relative):
            continue
        live_hash = context.tree.hash_file(relative, mode=0o600)
        if live_hash == manifest["hash"]:
            context.tree.unlink_file(relative, expected_hash=manifest["hash"], mode=0o600)
        elif path in before_by_path and live_hash == before_by_path[path]["hash"]:
            continue
        else:
            reject(f"rollback found a user-modified manifest: {path}", RECOVERY_REQUIRED)
    for index, manifest in enumerate(before_manifests):
        target = context.relative(manifest["path"], "rollback owned manifest")
        backup = manifest_backup(context, journal["txid"], index)
        if context.tree.lexists(backup):
            if context.tree.hash_file(backup, mode=0o600) != manifest["hash"]:
                reject("rollback manifest backup drifted", RECOVERY_REQUIRED)
            if context.tree.lexists(target):
                if context.tree.hash_file(target, mode=0o600) != manifest["hash"]:
                    reject("rollback target blocks manifest restore", RECOVERY_REQUIRED)
                context.tree.unlink_file(target, expected_hash=manifest["hash"], mode=0o600)
            context.tree.rename(backup, target, create_destination_parent=True)
        elif not context.tree.lexists(target) or context.tree.hash_file(target, mode=0o600) != manifest["hash"]:
            reject("rollback cannot locate an owned manifest", RECOVERY_REQUIRED)


def rollback_transaction(context: Context, journal: dict, test_barriers: bool) -> str:
    run_barrier("rollback_started", context, test_barriers)
    plan = journal["plan"]
    txid = journal["txid"]
    restore_manifest_backups(context, journal)
    if plan["operation"] == "uninstall":
        for index, record in enumerate(plan["removeVersions"]):
            target = context.relative(record["path"], "rollback version")
            backup = version_backup(context, txid, index)
            if context.tree.lexists(backup):
                context.tree.verify_tree(backup, record)
                if context.tree.lexists(target):
                    reject("rollback version target is unexpectedly occupied", RECOVERY_REQUIRED)
                context.tree.rename(backup, target, create_destination_parent=True)
            elif not context.tree.lexists(target):
                reject("rollback cannot locate an owned version", RECOVERY_REQUIRED)
            context.tree.verify_tree(target, record)
    publish = plan["publishVersion"]
    if publish is not None:
        target = context.relative(publish["path"], "rollback published version")
        if context.tree.lexists(target):
            context.tree.remove_tree(target, publish)
    staged = staged_version(context, txid)
    if context.tree.lexists(staged):
        context.tree.remove_tree(staged)
    before = plan["before"]
    if before is None:
        if context.tree.lexists(context.receipt2_rel):
            reject("rollback found an unexpected receipt-v2", RECOVERY_REQUIRED)
    else:
        if not context.tree.lexists(before["receiptPath"]):
            backup = receipt_backup(context, txid)
            if not context.tree.lexists(backup):
                reject("rollback cannot restore the receipt", RECOVERY_REQUIRED)
            if context.tree.hash_file(backup, mode=0o600) != before["receiptHash"]:
                reject("rollback receipt backup drifted", RECOVERY_REQUIRED)
            context.tree.copy_file_preserve(backup, before["receiptPath"])
        elif context.tree.hash_file(before["receiptPath"], mode=0o600) != before["receiptHash"]:
            reject("rollback live receipt drifted", RECOVERY_REQUIRED)
        restored_info = context.tree.lstat(before["receiptPath"])
        if (
            restored_info.st_uid != before["receiptUid"]
            or restored_info.st_gid != before["receiptGid"]
            or mode_text(restored_info.st_mode) != before["receiptMode"]
            or restored_info.st_nlink != 1
        ):
            reject("rollback receipt metadata was not preserved", RECOVERY_REQUIRED)
        if before["receiptFormat"] == 1 and context.tree.lexists(context.receipt2_rel):
            reject("rollback found receipt-v2 before its commit point", RECOVERY_REQUIRED)
    update_phase(context, journal, "rolled-back")
    return "rolled-back"


def recover_one(context: Context, journal: dict, test_barriers: bool) -> str:
    if receipt_commit_state(context, journal["plan"]):
        return finalize_transaction(context, journal)
    return rollback_transaction(context, journal, test_barriers)


def execute_plan(context: Context, plan: dict, test_barriers: bool) -> dict:
    if plan["operation"] == "noop":
        return {"action": plan["action"], "operation": "noop", "result": "noop"}
    journal = begin_journal(context, plan)
    txid = journal["txid"]
    run_barrier("journal_durable", context, test_barriers)
    try:
        prepare_transaction_directories(context, txid)
        backup_receipt(context, journal)
        update_phase(context, journal, "receipt-backed-up")
        if plan["operation"] == "uninstall":
            backup_manifests(context, journal)
            move_uninstall_versions(context, journal)
            run_barrier("version_published", context, test_barriers)
            run_barrier("manifest_switched", context, test_barriers)
        else:
            publish_version(context, journal)
            if plan["publishVersion"] is not None:
                run_barrier("version_published", context, test_barriers)
            backup_manifests(context, journal)
            publish_manifests(context, journal)
            run_barrier("manifest_switched", context, test_barriers)
        commit_receipt(context, journal, test_barriers)
        finalize_transaction(context, journal)
        return {"action": plan["action"], "operation": plan["operation"], "result": "committed", "txid": txid}
    except BaseException as original:
        try:
            current = read_journal(context, txid)
            recovered = recover_one(context, current, test_barriers)
        except BaseException as recovery_error:
            raise TransactionError(
                RECOVERY_REQUIRED,
                f"transaction {txid} requires recover: {recovery_error} (original: {original})",
            ) from recovery_error
        if recovered == "rolled-back":
            raise TransactionError(ROLLED_BACK, f"transaction {txid} rolled back after: {original}") from original
        return {
            "action": plan["action"],
            "operation": plan["operation"],
            "result": "committed-and-recovered",
            "txid": txid,
        }


def add_roots(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--session-root", required=True)
    parser.add_argument("--home-root", required=True)


def add_operation_inputs(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--action", choices=("install", "upgrade", "uninstall"), required=True)
    parser.add_argument("--package-root")
    parser.add_argument("--browser", action="append", default=[])
    parser.add_argument("--extension-id", action="append", default=[])
    parser.add_argument("--edge-user-data-dir")


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan_parser = subparsers.add_parser("plan", help="emit a canonical dry-run plan")
    add_roots(plan_parser)
    add_operation_inputs(plan_parser)

    apply_parser = subparsers.add_parser("apply", help="recompute and apply a confirmed plan")
    add_roots(apply_parser)
    add_operation_inputs(apply_parser)
    apply_parser.add_argument("--plan-digest", required=True)
    apply_parser.add_argument("--confirm", required=True)
    apply_parser.add_argument("--test-barriers", action="store_true")

    recover_parser = subparsers.add_parser("recover", help="recover the single unfinished transaction")
    add_roots(recover_parser)
    recover_parser.add_argument("--test-barriers", action="store_true")
    return parser.parse_args(argv)


def command_plan(args: argparse.Namespace) -> dict:
    context = make_context(args.session_root, args.home_root)
    try:
        return compute_plan(args, context)
    finally:
        close_context(context)


def command_apply(args: argparse.Namespace) -> dict:
    if not SHA256_RE.fullmatch(args.plan_digest):
        reject("--plan-digest must be a lowercase SHA-256")
    context = make_context(args.session_root, args.home_root)
    lock: int | None = None
    try:
        lock = acquire_lock(context, args.test_barriers)
        plan = compute_plan(args, context)
        if plan["planDigest"] != args.plan_digest:
            reject("the confirmed plan is stale", STALE_PLAN)
        expected_confirmation = f"{args.action}:{plan['planDigest']}"
        if args.confirm != expected_confirmation:
            reject("confirmation must bind action and current plan digest", STALE_PLAN)
        return execute_plan(context, plan, args.test_barriers)
    finally:
        if lock is not None:
            fcntl.flock(lock, fcntl.LOCK_UN)
            os.close(lock)
        close_context(context)


def command_recover(args: argparse.Namespace) -> dict:
    context = make_context(args.session_root, args.home_root)
    lock: int | None = None
    try:
        lock = acquire_lock(context, args.test_barriers)
        active, scaffolds = scan_transactions(context)
        for txid in scaffolds:
            recover_scaffold(context, txid)
        if not active:
            if scaffolds:
                return {"action": "recover", "result": "scaffold-cleaned", "txids": scaffolds}
            return {"action": "recover", "result": "noop"}
        txid, journal = active[0]
        result = recover_one(context, journal, args.test_barriers)
        return {"action": "recover", "result": result, "txid": txid}
    finally:
        if lock is not None:
            fcntl.flock(lock, fcntl.LOCK_UN)
            os.close(lock)
        close_context(context)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_arguments(argv or sys.argv[1:])
    try:
        if args.command == "plan":
            result = command_plan(args)
        elif args.command == "apply":
            result = command_apply(args)
        elif args.command == "recover":
            result = command_recover(args)
        else:
            reject(f"unsupported command: {args.command}")
        sys.stdout.buffer.write(canonical_bytes(result))
        return SUCCESS
    except TransactionError as error:
        print(f"transaction-host: {error}", file=sys.stderr)
        return error.code
    except stable_host.StableHostError as error:
        print(f"transaction-host: {error}", file=sys.stderr)
        return INVALID_UNSAFE
    except BarrierError as error:
        print(f"transaction-host: unrecovered test barrier: {error}", file=sys.stderr)
        return RECOVERY_REQUIRED
    except BaseException as error:
        print(f"transaction-host: internal error: {error}", file=sys.stderr)
        return INTERNAL_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
