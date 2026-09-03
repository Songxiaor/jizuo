#!/usr/bin/env python3
"""Build and verify LinkDigest's non-secret Chromium extension identity artifact.

The only private-key operation is ``generate-development-key``. It refuses a
repository path and writes an explicitly supplied, new development-only PEM.
All other commands consume only the public manifest key and the WXT build
output, so candidates never need private signing material.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
IDENTITY_PATH = Path("config/extension-identity.json")
APP_RELEASE_PATH = Path("config/app-release.json")
DISPLAY_PATH = Path("apps/desktop/Sources/LinkDigestCore/Resources/product-display.json")
NATIVE_HOST_PATH = Path("config/native-host.json")
BUILD_OUTPUT = Path("apps/browser-extension/.output/chrome-mv3")
ARTIFACT_DIRECTORY = Path("apps/browser-extension/identity-artifact")
ARTIFACT_FILENAME_GLOB = "LinkDigest-extension-*-chromium.zip"
TEMPLATE_DIRECTORY = ARTIFACT_DIRECTORY / "native-host-manifests"
APP_INSTALLER_RESOURCE_DIRECTORY = Path("apps/desktop/Sources/LinkDigestCore/Resources/browser-support/native-host-manifests")
APP_INSTALLER_INTEGRITY_PATH = Path("apps/desktop/Sources/LinkDigestCore/Resources/browser-support/manifest-integrity.json")
PLACEHOLDER_HOST_PATH = "__LINKDIGEST_NATIVE_HOST_PATH__"
CHROMIUM_ID_ALPHABET = "abcdefghijklmnop"
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
TEMPLATE_BROWSERS = ("brave", "chrome", "edge")


class IdentityArtifactError(RuntimeError):
    pass


def fail(message: str) -> "None":
    raise IdentityArtifactError(message)


def canonical_json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be one JSON object")
    return value


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def versioned_artifact_paths(root: Path) -> tuple[Path, ...]:
    """Return every versioned extension ZIP in the active artifact directory.

    The directory is a delivery boundary, not an archive.  A same-ID ZIP from
    an earlier version would still be loadable by Chromium and must therefore
    be treated as an unsafe extra artifact rather than ignored by the packer.
    """
    directory = root / ARTIFACT_DIRECTORY
    require_real_directory(directory, "extension artifact")
    return tuple(sorted(directory.glob(ARTIFACT_FILENAME_GLOB), key=lambda path: os.fsencode(path.name)))


def require_exact_configured_artifact(root: Path, identity: dict[str, str | int]) -> Path:
    expected = root / str(identity["artifactSource"])
    artifacts = versioned_artifact_paths(root)
    if len(artifacts) != 1:
        names = ", ".join(path.name for path in artifacts) or "<none>"
        fail(f"extension artifact directory must contain exactly one {ARTIFACT_FILENAME_GLOB}: {names}")
    if artifacts[0] != expected:
        fail("extension artifact directory entry must equal the configured artifactSource")
    return expected


def require_real_directory(path: Path, label: str) -> None:
    """Reject every symlink component before a checked-in artifact write."""
    if not path.is_absolute():
        path = path.resolve(strict=False)
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except OSError as error:
            fail(f"{label} directory is unavailable: {error}")
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            fail(f"{label} directory must not contain a symlink or non-directory component")


def atomic_replace_regular(destination: Path, payload: bytes, mode: int, label: str) -> None:
    require_real_directory(destination.parent, label)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    directory_fd = os.open(destination.parent, flags)
    try:
        try:
            info = os.stat(destination.name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            info = None
        if info is not None:
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                fail(f"{label} destination is not one safe regular file")
        temporary = f".{destination.name}.{uuid.uuid4().hex}.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), mode, dir_fd=directory_fd)
        try:
            with os.fdopen(descriptor, "wb", closefd=False) as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.fchmod(descriptor, mode)
            os.close(descriptor)
            descriptor = -1
            os.replace(temporary, destination.name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
            os.fsync(directory_fd)
        except BaseException:
            if descriptor >= 0:
                os.close(descriptor)
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            raise
    finally:
        os.close(directory_fd)


def chromium_extension_id(public_der: bytes) -> str:
    digest = hashlib.sha256(public_der).digest()
    return "".join(CHROMIUM_ID_ALPHABET[nibble] for byte in digest[:16] for nibble in (byte >> 4, byte & 0x0F))


def manifest_key_from_public_der(public_der: bytes) -> str:
    return base64.b64encode(public_der).decode("ascii")


def validate_relative(value: str, label: str) -> Path:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail(f"{label} must be a safe relative path")
    return Path(path)


def load_identity(root: Path = ROOT) -> dict[str, str | int]:
    value = load_json(root / IDENTITY_PATH, "extension identity")
    expected = {"artifactName", "artifactSource", "extensionID", "formatVersion", "manifestKey", "version"}
    if set(value) != expected:
        fail("extension identity keys drifted")
    if value["formatVersion"] != 1 or not isinstance(value["formatVersion"], int):
        fail("extension identity formatVersion must be 1")
    for field in ("artifactName", "artifactSource", "extensionID", "manifestKey", "version"):
        if not isinstance(value[field], str) or not value[field]:
            fail(f"extension identity {field} must be a non-empty string")
    if not all("a" <= character <= "p" for character in value["extensionID"]) or len(value["extensionID"]) != 32:
        fail("extension identity must be one 32-character Chromium ID")
    artifact_source = validate_relative(value["artifactSource"], "extension identity artifactSource")
    if artifact_source.name != value["artifactName"] or artifact_source.parent != ARTIFACT_DIRECTORY:
        fail("extension identity artifact path must be the exact artifact directory entry")
    try:
        public_der = base64.b64decode(value["manifestKey"], validate=True)
    except ValueError as error:
        fail(f"extension identity manifestKey is invalid base64: {error}")
    if not public_der or chromium_extension_id(public_der) != value["extensionID"]:
        fail("extension identity manifestKey does not derive extensionID")
    return value


def load_display(root: Path = ROOT) -> dict[str, str | int]:
    value = load_json(root / DISPLAY_PATH, "product display")
    expected = {"displayName", "extensionDescription", "extensionDisplayName", "formatVersion"}
    if set(value) != expected or value["formatVersion"] != 1:
        fail("product display keys or formatVersion drifted")
    for field in ("displayName", "extensionDescription", "extensionDisplayName"):
        if not isinstance(value[field], str) or not value[field].strip():
            fail(f"product display {field} must be a non-empty string")
    return value


def load_public_version(root: Path = ROOT) -> str:
    value = load_json(root / APP_RELEASE_PATH, "app release")
    version = value.get("shortVersion")
    if value.get("formatVersion") != 1 or not isinstance(version, str) or not version:
        fail("app release shortVersion is invalid")
    return version


def native_host_template(identity: dict[str, str | int], host: dict[str, Any]) -> dict[str, Any]:
    return {
        "allowed_origins": [f"chrome-extension://{identity['extensionID']}/"],
        "description": "LinkDigest Native Messaging Host",
        "name": host["hostName"],
        "path": PLACEHOLDER_HOST_PATH,
        "type": "stdio",
    }


def validate_native_host_binding(root: Path, identity: dict[str, str | int]) -> dict[str, Any]:
    host = load_json(root / NATIVE_HOST_PATH, "native-host config")
    if host.get("releaseExtensionIDs") != [identity["extensionID"]] or host.get("releaseExtensionIDsStatus") != "frozen":
        fail("native-host release IDs do not exactly bind the extension identity")
    if not isinstance(host.get("hostName"), str) or not host["hostName"]:
        fail("native-host hostName is invalid")
    return host


def verify_display_wiring(root: Path) -> None:
    expected_references = {
        "apps/browser-extension/wxt.config.ts": [
            "product-display.json",
            "app-release.json",
            "name: productDisplay.displayName",
            "description: productDisplay.extensionDescription",
            "version_name: appRelease.shortVersion",
        ],
        "apps/browser-extension/entrypoints/popup/main.ts": ["browser.runtime.getManifest()", "manifest.name"],
        "apps/desktop/Sources/LinkDigestApp/LinkDigestApp.swift": ["WindowGroup(ProductDisplay.name)"],
        "apps/desktop/Sources/LinkDigestApp/HistoryContentView.swift": ["ProductDisplay.extensionName"],
    }
    for relative, markers in expected_references.items():
        try:
            text = (root / relative).read_text(encoding="utf-8")
        except OSError as error:
            fail(f"display wiring source is unavailable: {error}")
        if any(marker not in text for marker in markers):
            fail(f"display wiring drifted in {relative}")


def output_files(output: Path) -> list[Path]:
    if not output.is_dir() or output.is_symlink():
        fail("WXT build output is missing or unsafe")
    files: list[Path] = []
    for current, directories, names in os.walk(output, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        names.sort(key=os.fsencode)
        for name in names:
            path = Path(current) / name
            info = path.lstat()
            relative = path.relative_to(output)
            if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                fail(f"WXT output contains an unsafe entry: {relative}")
            if any(part in ("", ".", "..") for part in relative.parts):
                fail("WXT output path is unsafe")
            files.append(path)
    if not files:
        fail("WXT build output is empty")
    return sorted(files, key=lambda path: os.fsencode(path.relative_to(output).as_posix()))


def validate_built_manifest(
    output: Path,
    identity: dict[str, str | int],
    display: dict[str, str | int],
    public_version: str,
) -> dict[str, Any]:
    manifest = load_json(output / "manifest.json", "built extension manifest")
    expected = {
        "key": identity["manifestKey"],
        "name": display["displayName"],
        "description": display["extensionDescription"],
        "version": identity["version"],
        "version_name": public_version,
    }
    for field, expected_value in expected.items():
        if manifest.get(field) != expected_value:
            fail(f"built extension manifest {field} drifted from canonical config")
    return manifest


def deterministic_zip(source: Path, destination: Path) -> str:
    files = output_files(source)
    if destination.exists() or destination.is_symlink():
        fail("deterministic ZIP destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9, strict_timestamps=True) as archive:
        for path in files:
            relative = path.relative_to(source).as_posix()
            info = zipfile.ZipInfo(relative, date_time=ZIP_TIMESTAMP)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    os.chmod(destination, 0o644)
    return sha256_file(destination)


def verify_zip(
    artifact: Path,
    identity: dict[str, str | int],
    display: dict[str, str | int],
    public_version: str,
) -> list[str]:
    if artifact.is_symlink() or not artifact.is_file() or stat.S_IMODE(artifact.lstat().st_mode) != 0o644:
        fail("extension artifact must be one real 0644 file")
    try:
        with zipfile.ZipFile(artifact, "r") as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if names != sorted(names, key=os.fsencode) or len(names) != len(set(names)) or "manifest.json" not in names:
                fail("extension artifact entries are not exact deterministic order")
            for info in infos:
                if info.is_dir() or info.date_time != ZIP_TIMESTAMP or info.external_attr >> 16 != 0o100644:
                    fail("extension artifact ZIP metadata drifted")
                relative = PurePosixPath(info.filename)
                if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
                    fail("extension artifact contains an unsafe path")
            manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        fail(f"extension artifact is invalid: {error}")
    if not isinstance(manifest, dict):
        fail("extension artifact manifest must be one JSON object")
    for field, expected in {
        "key": identity["manifestKey"],
        "name": display["displayName"],
        "description": display["extensionDescription"],
        "version": identity["version"],
        "version_name": public_version,
    }.items():
        if manifest.get(field) != expected:
            fail(f"extension artifact manifest {field} drifted")
    return names


def extract_verified_zip(
    artifact: Path,
    destination: Path,
    identity: dict[str, str | int],
    display: dict[str, str | int],
    public_version: str,
) -> Path:
    names = verify_zip(artifact, identity, display, public_version)
    if destination.exists() or destination.is_symlink():
        fail("extension artifact extraction destination already exists")
    destination.mkdir(parents=True, mode=0o700)
    with zipfile.ZipFile(artifact, "r") as archive:
        for name in names:
            target = destination / PurePosixPath(name)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(name))
            os.chmod(target, 0o644)
    return destination


def write_templates(root: Path, identity: dict[str, str | int], host: dict[str, Any], destination: Path) -> dict[str, str]:
    require_real_directory(destination, "native-host template")
    payload = canonical_json_bytes(native_host_template(identity, host))
    hashes: dict[str, str] = {}
    for browser in TEMPLATE_BROWSERS:
        path = destination / f"{browser}.json"
        atomic_replace_regular(path, payload, 0o644, "native-host template")
        hashes[browser] = sha256_file(path)
    return hashes


def verify_templates(root: Path, identity: dict[str, str | int], host: dict[str, Any], directory: Path) -> dict[str, str]:
    expected = canonical_json_bytes(native_host_template(identity, host))
    entries = {path.name for path in directory.iterdir()} if directory.is_dir() and not directory.is_symlink() else set()
    if entries != {f"{browser}.json" for browser in TEMPLATE_BROWSERS}:
        fail("native-host browser templates are not the exact Chrome/Brave/Edge set")
    hashes: dict[str, str] = {}
    for browser in TEMPLATE_BROWSERS:
        path = directory / f"{browser}.json"
        if path.is_symlink() or not path.is_file() or path.read_bytes() != expected:
            fail(f"native-host {browser} template drifted")
        hashes[browser] = sha256_file(path)
    return hashes


def verify_app_installer_resources(root: Path, identity: dict[str, str | int], host: dict[str, Any]) -> dict[str, str]:
    """Bind the runtime Swift resource copies to the frozen Loop 7 templates.

    The app cannot read a candidate handoff at install time, so its bundled
    copies are a separate security boundary.  Exact bytes plus the compact
    integrity descriptor prevent either side from silently drifting.
    """
    expected_hashes = verify_templates(root, identity, host, root / TEMPLATE_DIRECTORY)
    runtime_hashes = verify_templates(root, identity, host, root / APP_INSTALLER_RESOURCE_DIRECTORY)
    if runtime_hashes != expected_hashes:
        fail("app browser-support templates drifted from the frozen extension templates")
    descriptor = load_json(root / APP_INSTALLER_INTEGRITY_PATH, "app browser-support integrity")
    expected_descriptor = {
        "extensionID": identity["extensionID"],
        "formatVersion": 1,
        "hostName": host["hostName"],
        "templates": expected_hashes,
        "version": identity["version"],
    }
    if descriptor != expected_descriptor:
        fail("app browser-support integrity descriptor drifted")
    return runtime_hashes


def build_live_artifacts(root: Path) -> dict[str, Any]:
    identity = load_identity(root)
    display = load_display(root)
    public_version = load_public_version(root)
    host = validate_native_host_binding(root, identity)
    verify_display_wiring(root)
    output = root / BUILD_OUTPUT
    validate_built_manifest(output, identity, display, public_version)
    artifact = root / str(identity["artifactSource"])
    require_real_directory(artifact.parent, "extension artifact")
    if artifact.exists() or artifact.is_symlink():
        info = artifact.lstat()
        if artifact.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            fail("extension artifact destination is not one safe regular file")
    temporary_artifact = artifact.parent / f".{artifact.name}.{uuid.uuid4().hex}.tmp"
    artifact_hash = deterministic_zip(output, temporary_artifact)
    try:
        atomic_replace_regular(artifact, temporary_artifact.read_bytes(), 0o644, "extension artifact")
    finally:
        if os.path.lexists(temporary_artifact):
            temporary_artifact.unlink()
    require_exact_configured_artifact(root, identity)
    template_hashes = write_templates(root, identity, host, root / TEMPLATE_DIRECTORY)
    app_templates = verify_app_installer_resources(root, identity, host)
    return {"appInstallerTemplateHashes": app_templates, "artifactHash": artifact_hash, "extensionID": identity["extensionID"], "templateHashes": template_hashes, "version": identity["version"]}


def _determinism_scratch_root() -> str:
    """A scratch root for the build-twice-and-compare check below.

    macOS keeps using `/private/tmp`: the rest of this repo's release tooling
    pins that exact path on purpose (it is the real directory behind `/tmp`,
    so a redirected `TMPDIR` cannot move release work somewhere unexpected),
    and those scripts reject anything else.

    That convention is macOS-only, but this particular script is not: it also
    runs on the Linux `verify-web` job, where `/private/tmp` simply does not
    exist and `TemporaryDirectory` fails with FileNotFoundError before the
    determinism check ever runs. That job had therefore never passed.

    Nothing security-sensitive lives here — the directory only holds two
    freshly built copies of the extension ZIP that are compared and discarded,
    and `TemporaryDirectory` still creates it 0700 with a random name.
    """
    private_tmp = "/private/tmp"
    if os.path.isdir(private_tmp):
        return private_tmp
    return tempfile.gettempdir()


def verify_live_artifacts(root: Path) -> dict[str, Any]:
    identity = load_identity(root)
    display = load_display(root)
    public_version = load_public_version(root)
    host = validate_native_host_binding(root, identity)
    verify_display_wiring(root)
    output = root / BUILD_OUTPUT
    validate_built_manifest(output, identity, display, public_version)
    artifact = require_exact_configured_artifact(root, identity)
    entries = verify_zip(artifact, identity, display, public_version)
    with tempfile.TemporaryDirectory(prefix="linkdigest-extension-identity.", dir=_determinism_scratch_root()) as temporary:
        first = Path(temporary) / "one.zip"
        second = Path(temporary) / "two.zip"
        first_hash = deterministic_zip(output, first)
        second_hash = deterministic_zip(output, second)
        if first_hash != second_hash or first.read_bytes() != second.read_bytes() or artifact.read_bytes() != first.read_bytes():
            fail("extension source-to-ZIP build is not deterministic or checked-in artifact is stale")
    templates = verify_templates(root, identity, host, root / TEMPLATE_DIRECTORY)
    app_templates = verify_app_installer_resources(root, identity, host)
    return {"appInstallerTemplateHashes": app_templates, "artifactHash": sha256_file(artifact), "entries": entries, "extensionID": identity["extensionID"], "templateHashes": templates, "version": identity["version"]}


def safe_new_private_key_path(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute() or path.name != "linkdigest-loop7-development-extension.pem" or path.suffix != ".pem":
        fail("development private key path must be an absolute linkdigest-loop7-development-extension.pem path")
    try:
        path.relative_to(ROOT)
    except ValueError:
        pass
    else:
        fail("development private key must stay outside the repository")
    if path.exists() or path.is_symlink():
        fail("development private key destination already exists")
    return path


def generate_development_key(value: str) -> dict[str, str]:
    path = safe_new_private_key_path(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    result = subprocess.run(["/usr/bin/openssl", "genrsa", "-out", str(path), "2048"], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        fail("openssl could not generate the development-only extension key")
    os.chmod(path, 0o600)
    public = subprocess.run(["/usr/bin/openssl", "rsa", "-in", str(path), "-pubout", "-outform", "DER"], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if public.returncode != 0 or not public.stdout:
        fail("openssl could not derive the development extension public key")
    return {
        "extensionID": chromium_extension_id(public.stdout),
        "manifestKey": manifest_key_from_public_der(public.stdout),
        "privateKeyPath": str(path),
        "publicKeySHA256": sha256_bytes(public.stdout),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    generate = subcommands.add_parser("generate-development-key")
    generate.add_argument("--private-key-path", required=True)
    subcommands.add_parser("build-live")
    subcommands.add_parser("verify-live")
    verify = subcommands.add_parser("verify-artifact")
    verify.add_argument("--artifact", required=True)
    args = parser.parse_args()
    try:
        if args.command == "generate-development-key":
            result = generate_development_key(args.private_key_path)
        elif args.command == "build-live":
            result = build_live_artifacts(ROOT)
        elif args.command == "verify-live":
            result = verify_live_artifacts(ROOT)
        else:
            identity = load_identity(ROOT)
            display = load_display(ROOT)
            public_version = load_public_version(ROOT)
            entries = verify_zip(Path(args.artifact), identity, display, public_version)
            result = {"artifactHash": sha256_file(Path(args.artifact)), "entries": entries, "extensionID": identity["extensionID"], "version": identity["version"]}
        print(canonical_json_bytes(result).decode("utf-8"), end="")
        return 0
    except IdentityArtifactError as error:
        print(f"extension-identity-artifact: {error}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
