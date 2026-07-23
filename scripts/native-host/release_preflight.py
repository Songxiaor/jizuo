#!/usr/bin/env python3
"""Read-only release-preflight reporting for LinkDigest Native Host.

This is intentionally a planning harness, not an installer.  It never creates,
updates, deletes, renames, signs, notarizes, staples, or uploads anything.
Production evidence comes only from existing package/artifact paths and local
codesign, spctl, and stapler read-only queries.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Sequence

# A report must not leave Python import caches in the repository, even when the
# caller did not set PYTHONDONTWRITEBYTECODE.
sys.dont_write_bytecode = True

import stable_host


POLICY_RELATIVE = Path("config/native-host-release-policy.json")
READY = 0
BLOCKED = 10
INVALID_UNSAFE = 2
INTERNAL = 70
TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
DEVELOPER_ID_AUTHORITY_RE = re.compile(r"^Authority=Developer ID Application: .+$", re.MULTILINE)
ADHOC_SIGNATURE_RE = re.compile(r"^Signature=adhoc$", re.MULTILINE)
RUNTIME_FLAGS_RE = re.compile(
    r"^flags=0x[0-9A-Fa-f]+\((?:[A-Za-z0-9_-]+,)*runtime(?:,[A-Za-z0-9_-]+)*\)$",
    re.MULTILINE,
)
TEAM_IDENTIFIER_RE = re.compile(r"^TeamIdentifier=([A-Z0-9]{10})$", re.MULTILINE)
SPCTL_SOURCE_RE = re.compile(r"^source=Notarized Developer ID$", re.MULTILINE)
SPCTL_ORIGIN_RE = re.compile(r"^origin=Developer ID Application: .+$", re.MULTILINE)
APPLE_QUERY_TIMEOUT_SECONDS = 5
APPLE_QUERY_ENV = {
    "HOME": "/var/empty",
    "TMPDIR": "/private/tmp",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "C",
    "LC_ALL": "C",
}


class PreflightError(RuntimeError):
    """An unsafe input or strict-schema failure (exit 2)."""


def fail(message: str) -> "None":
    raise PreflightError(message)


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def sha256_json(value: object) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not valid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def load_policy(root: Path | None = None) -> dict[str, Any]:
    root = root or repository_root()
    policy = load_json_object(root / POLICY_RELATIVE, "release policy")
    required = {
        "formatVersion",
        "installAuthorization",
        "distribution",
        "browserTargets",
        "teamIDStatus",
        "teamID",
    }
    if set(policy) != required:
        fail("release policy keys do not match the frozen format")
    if policy["formatVersion"] != 1 or isinstance(policy["formatVersion"], bool):
        fail("release policy formatVersion must be 1")
    authorization = policy["installAuthorization"]
    if not isinstance(authorization, dict) or set(authorization) != {"scope", "sudo", "separateAuthorizationRequired"}:
        fail("release policy installAuthorization keys do not match the frozen format")
    if authorization != {"scope": "current-user", "sudo": "forbidden", "separateAuthorizationRequired": True}:
        fail("release policy must freeze current-user, no-sudo, separate authorization")
    distribution = policy["distribution"]
    if not isinstance(distribution, dict) or set(distribution) != {"target", "artifact", "signingIdentity"}:
        fail("release policy distribution keys do not match the frozen format")
    if distribution != {"target": "P0-candidate", "artifact": "notarized-stapled-dmg", "signingIdentity": "Developer ID Application"}:
        fail("release policy distribution is not the frozen P0 candidate")
    targets = policy["browserTargets"]
    if not isinstance(targets, dict) or set(targets) != {"brave", "chrome", "edge"}:
        fail("release policy browserTargets keys do not match the frozen format")
    expected_targets = {
        "brave": {"browser": "brave", "manifestRelativePath": "Library/Application Support/Google/Chrome/NativeMessagingHosts", "profilePolicy": "default-user-target-only"},
        "chrome": {"browser": "chrome", "manifestRelativePath": "Library/Application Support/Google/Chrome/NativeMessagingHosts", "profilePolicy": "default-user-target-only"},
        "edge": {"browser": "edge", "manifestRelativePath": "Library/Application Support/Microsoft Edge/NativeMessagingHosts", "profilePolicy": "default-user-target-only"},
    }
    if targets != expected_targets:
        fail("release policy browser targets do not match the frozen Chrome/Brave shared and Edge independent targets")
    status = policy["teamIDStatus"]
    if not isinstance(status, str) or status not in {"not-frozen", "frozen"}:
        fail("release policy teamIDStatus is invalid")
    if status == "not-frozen" and policy["teamID"] is not None:
        fail("unfrozen Team ID must be null")
    if status == "frozen" and (not isinstance(policy["teamID"], str) or not TEAM_ID_RE.fullmatch(policy["teamID"])):
        fail("frozen Team ID must be a 10-character Apple Team ID")
    return policy


def canonical_existing_path(
    value: str | None,
    option: str,
    *,
    kind: str,
    required_suffix: str | None = None,
    require_single_owned_file: bool = False,
) -> Path | None:
    if value is None:
        return None
    if (
        not isinstance(value, str)
        or not value
        or value == "/"
        or not value.startswith("/")
        or "\x00" in value
        or "\r" in value
        or "\n" in value
        or "//" in value
        or "/./" in value
        or "/../" in value
        or value.endswith("/")
        or value.endswith("/.")
        or value.endswith("/..")
    ):
        fail(f"{option} must be an existing canonical absolute path")
    candidate = Path(value)
    if not candidate.is_absolute() or any(part in {"", ".", ".."} for part in candidate.parts):
        fail(f"{option} must be an existing canonical absolute path")
    current = Path(candidate.anchor)
    for part in candidate.parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except OSError:
            fail(f"{option} cannot be inspected safely")
        if stat.S_ISLNK(info.st_mode):
            fail(f"{option} must not traverse a symlink")
    if kind == "directory" and not candidate.is_dir():
        fail(f"{option} must be a directory")
    if kind == "file" and not candidate.is_file():
        fail(f"{option} must be a regular file")
    info = candidate.lstat()
    if required_suffix is not None and candidate.suffix.lower() != required_suffix:
        fail(f"{option} must use the {required_suffix} suffix")
    if info.st_uid != os.geteuid():
        fail(f"{option} must be owned by the current user")
    if require_single_owned_file and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
        fail(f"{option} must be a single-link regular file")
    return candidate


def run_readonly(
    command: list[str],
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> tuple[int, str]:
    """Run a fixed Apple query with no caller environment or writable stdin."""
    if not is_fixed_apple_query(command):
        return 126, ""
    try:
        result = runner(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=dict(APPLE_QUERY_ENV),
            timeout=APPLE_QUERY_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return 124, ""
    except FileNotFoundError:
        return 127, ""
    except OSError:
        return 126, ""
    return result.returncode, result.stdout + result.stderr


def is_fixed_apple_query(command: Sequence[str]) -> bool:
    if not all(isinstance(item, str) and item for item in command):
        return False
    return (
        (len(command) == 5 and command[:4] == ["/usr/bin/codesign", "--verify", "--deep", "--strict"])
        or (len(command) == 3 and command[:2] == ["/usr/bin/codesign", "-dvv"])
        or (
            len(command) == 8
            and command[:7]
            == ["/usr/sbin/spctl", "-a", "-vv", "--type", "open", "--ignore-cache", "--no-cache"]
        )
        or (len(command) == 4 and command[:3] == ["/usr/bin/xcrun", "stapler", "validate"])
    )


def notarization_from_spctl_text(text: str) -> str:
    """Accept only one anchored notarization source plus Developer ID origin."""
    sources = SPCTL_SOURCE_RE.findall(text)
    origins = SPCTL_ORIGIN_RE.findall(text)
    return "present" if len(sources) == 1 and len(origins) == 1 else "missing"


def evidence_from_text(text: str, *, expected_team_id: str | None) -> dict[str, str]:
    authority = DEVELOPER_ID_AUTHORITY_RE.search(text) is not None
    adhoc = ADHOC_SIGNATURE_RE.search(text) is not None
    runtime = RUNTIME_FLAGS_RE.search(text) is not None
    team_matches = TEAM_IDENTIFIER_RE.findall(text)
    team_id = team_matches[0] if len(team_matches) == 1 else None
    if adhoc:
        signature = "adhoc"
    elif authority:
        signature = "developer-id"
    else:
        signature = "missing-or-unrecognized"
    team = "missing" if team_id is None else ("match" if expected_team_id == team_id else "mismatch")
    return {"signature": signature, "hardenedRuntime": "present" if runtime else "missing", "team": team}


def inspect_artifact(
    artifact: Path | None,
    app: Path | None,
    expected_team_id: str | None,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, str]:
    if artifact is None:
        return {"artifact": "missing", "signature": "not-checked", "hardenedRuntime": "not-checked", "team": "not-checked", "notarization": "missing", "stapling": "missing"}
    if artifact.suffix.lower() != ".dmg":
        return {"artifact": "invalid", "signature": "not-checked", "hardenedRuntime": "not-checked", "team": "not-checked", "notarization": "missing", "stapling": "missing"}
    if app is None:
        signature = {"signature": "missing-or-unrecognized", "hardenedRuntime": "missing", "team": "missing"}
    else:
        verify_code, _ = run_readonly(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], runner=runner)
        code, text = run_readonly(["/usr/bin/codesign", "-dvv", str(app)], runner=runner)
        signature = evidence_from_text(text, expected_team_id=expected_team_id) if verify_code == 0 and code == 0 else {"signature": "missing-or-unrecognized", "hardenedRuntime": "missing", "team": "missing"}
    spctl_code, spctl_text = run_readonly(
        [
            "/usr/sbin/spctl",
            "-a",
            "-vv",
            "--type",
            "open",
            "--ignore-cache",
            "--no-cache",
            str(artifact),
        ],
        runner=runner,
    )
    stapler_code, _ = run_readonly(["/usr/bin/xcrun", "stapler", "validate", str(artifact)], runner=runner)
    return {
        "artifact": "present",
        **signature,
        "notarization": notarization_from_spctl_text(spctl_text) if spctl_code == 0 else "missing",
        "stapling": "present" if stapler_code == 0 else "missing",
    }


def ownership_state(receipt: Path | None, policy: dict[str, Any], config: dict[str, Any]) -> str:
    if receipt is None:
        return "absent"
    value = load_json_object(receipt, "ownership receipt")
    if set(value) != {"formatVersion", "owner", "manifestRelativePaths"}:
        return "malformed"
    if value.get("formatVersion") != 1 or value.get("owner") != "LinkDigest" or not isinstance(value.get("manifestRelativePaths"), list):
        return "malformed"
    paths = value["manifestRelativePaths"]
    if not paths or any(not isinstance(path, str) or path.startswith("/") or ".." in Path(path).parts for path in paths):
        return "malformed"
    expected = {f"{target['manifestRelativePath']}/{config['hostName']}.json" for target in policy["browserTargets"].values()}
    if set(paths) != expected or len(paths) != len(set(paths)):
        return "conflict"
    return "owned"


def planned_targets(policy: dict[str, Any], browsers: Sequence[str], edge_profile: str) -> list[dict[str, Any]]:
    if edge_profile != "default":
        fail("release preflight rejects every non-default Edge profile")
    requested = set(browsers)
    if not requested:
        requested = {"chrome", "brave", "edge"}
    unknown = requested - {"chrome", "brave", "edge"}
    if unknown:
        fail("release preflight received an unsupported browser")
    grouped: dict[tuple[str, str], list[str]] = {}
    for browser in requested:
        target = policy["browserTargets"][browser]
        grouped.setdefault((target["manifestRelativePath"], target["profilePolicy"]), []).append(browser)
    result = [
        {"browsers": sorted(browsers, key=("chrome", "brave", "edge").index), "manifestRelativePath": path, "profilePolicy": profile_policy}
        for (path, profile_policy), browsers in grouped.items()
    ]
    return sorted(result, key=lambda item: (item["manifestRelativePath"], item["browsers"]))


def evaluate_policy(
    config: dict[str, Any],
    policy: dict[str, Any],
    package_state: str,
    artifact: dict[str, str],
    ownership: str,
    targets: list[dict[str, Any]],
) -> dict[str, Any]:
    blockers: list[dict[str, str]] = []
    warnings: list[dict[str, str]] = []

    def block(code: str, message: str) -> None:
        blockers.append({"code": code, "message": message})

    if config["releaseExtensionIDsStatus"] != "frozen" or not config["releaseExtensionIDs"]:
        block("extension-ids-not-frozen", "Release extension IDs are not frozen in canonical config.")
    if policy["teamIDStatus"] != "frozen":
        block("team-id-not-frozen", "Developer Team ID is not frozen in release policy.")
    if package_state == "missing":
        block("package-missing", "Verified Native Host package input is required.")
    elif package_state != "verified":
        block("package-invalid", "Native Host package verification failed or drifted.")
    if artifact["artifact"] == "missing":
        block("distribution-artifact-missing", "Notarized and stapled DMG input is required.")
    elif artifact["artifact"] != "present":
        block("distribution-artifact-invalid", "Distribution artifact must be a canonical .dmg file.")
    if artifact["signature"] != "developer-id":
        block("developer-id-signature-missing", "Distribution evidence does not show Developer ID Application signing.")
    if artifact["hardenedRuntime"] != "present":
        block("hardened-runtime-missing", "Distribution evidence does not show hardened runtime.")
    if artifact["team"] != "match":
        block("team-id-mismatch", "Distribution signing Team ID does not match frozen policy.")
    if artifact["notarization"] != "present":
        block("notarization-missing", "Offline spctl evidence does not show notarization.")
    if artifact["stapling"] != "present":
        block("stapling-missing", "Offline stapler validation evidence is absent.")
    if ownership == "absent":
        warnings.append({"code": "ownership-receipt-absent", "message": "No current-user ownership receipt was supplied; no replacement is authorized."})
    elif ownership == "unknown":
        block("ownership-unknown", "Current-user ownership cannot be established.")
    elif ownership == "malformed":
        block("ownership-receipt-malformed", "Ownership receipt is malformed or conflicts with policy.")
    elif ownership == "conflict":
        block("ownership-receipt-conflict", "Ownership receipt does not match the frozen manifest targets.")
    return {
        "status": "READY" if not blockers else "BLOCKED",
        "blockers": sorted(blockers, key=lambda item: (item["code"], item["message"])),
        "warnings": sorted(warnings, key=lambda item: (item["code"], item["message"])),
        "targets": sorted(targets, key=lambda item: (item["manifestRelativePath"], item["browsers"])),
    }


def add_production_binding_blockers(verdict: dict[str, Any]) -> dict[str, Any]:
    """Keep production reporting fail-closed until r4 can verify real bindings.

    r3 may inspect supplied paths but cannot mount a DMG, inspect an installed
    namespace, or prove an external receipt belongs to the actual target leaves.
    Those actions need a separately authorized r4 packaging/install spike.
    """
    blockers = list(verdict["blockers"])
    blockers.extend(
        [
            {"code": "release-unit-binding-unverified", "message": "App and DMG are not verified as one offline release unit in r3."},
            {"code": "target-ownership-unverified", "message": "Current-user manifest target ownership is not verified in r3."},
        ]
    )
    return {
        **verdict,
        "status": "BLOCKED",
        "blockers": sorted(blockers, key=lambda item: (item["code"], item["message"])),
    }


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    root = repository_root()
    config = stable_host.load_config(root)
    policy = load_policy(root)
    package = canonical_existing_path(args.package_root, "--package-root", kind="directory")
    package_state = "missing"
    if package is not None:
        try:
            stable_host.verify_package(package, root)
            package_state = "verified"
        except stable_host.StableHostError:
            package_state = "invalid"
    artifact_path = canonical_existing_path(
        args.artifact_path,
        "--artifact-path",
        kind="file",
        required_suffix=".dmg",
        require_single_owned_file=True,
    )
    app_path = canonical_existing_path(args.app_path, "--app-path", kind="directory", required_suffix=".app")
    receipt_path = canonical_existing_path(
        args.ownership_receipt,
        "--ownership-receipt",
        kind="file",
        require_single_owned_file=True,
    )
    expected_team_id = policy["teamID"] if policy["teamIDStatus"] == "frozen" else None
    artifact = inspect_artifact(artifact_path, app_path, expected_team_id)
    ownership = ownership_state(receipt_path, policy, config)
    verdict = add_production_binding_blockers(
        evaluate_policy(config, policy, package_state, artifact, ownership, planned_targets(policy, args.browser, args.edge_profile))
    )
    report: dict[str, Any] = {
        "artifactEvidence": artifact,
        "blockers": verdict["blockers"],
        "formatVersion": 1,
        "mode": args.command,
        "ownership": ownership,
        "package": {"state": package_state},
        "separateAuthorizationRequired": True,
        "status": verdict["status"],
        "targets": verdict["targets"],
        "warnings": verdict["warnings"],
    }
    report["reportDigest"] = sha256_json(report)
    return report


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only LinkDigest release preflight report")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("report", "plan"):
        subparser = subparsers.add_parser(command, help="emit a read-only release-preflight report")
        subparser.add_argument("--package-root", help="existing canonical package directory (optional)")
        subparser.add_argument("--artifact-path", help="existing canonical notarized DMG path (optional)")
        subparser.add_argument("--app-path", help="existing canonical signed .app directory (optional)")
        subparser.add_argument("--ownership-receipt", help="existing canonical ownership receipt (optional)")
        subparser.add_argument("--browser", action="append", default=[], choices=("chrome", "brave", "edge"))
        subparser.add_argument("--edge-profile", default="default", help="only literal default is allowed")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = parse_args(argv if argv is not None else sys.argv[1:])
        report = build_report(args)
        sys.stdout.buffer.write(canonical_bytes(report))
        return READY if report["status"] == "READY" else BLOCKED
    except PreflightError as error:
        print(f"release-preflight: {error}", file=sys.stderr)
        return INVALID_UNSAFE
    except stable_host.StableHostError as error:
        print(f"release-preflight: {error}", file=sys.stderr)
        return INVALID_UNSAFE
    except Exception:
        print("release-preflight: internal error", file=sys.stderr)
        return INTERNAL


if __name__ == "__main__":
    raise SystemExit(main())
