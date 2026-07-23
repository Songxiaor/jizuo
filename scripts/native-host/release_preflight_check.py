#!/usr/bin/env python3
"""Deterministic, offline checks for the read-only r3 release preflight.

The production CLI never accepts synthetic signing evidence.  This checker uses
the pure evaluator only to cover READY-shaped evidence without Apple identity,
notarization, or network access.  One named /private/tmp audit root remains for
review; the CLI itself is asserted not to write HOME, TMPDIR, or the worktree.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/native-host/release_preflight.py"
sys.dont_write_bytecode = True
sys.path.insert(0, str(SCRIPT.parent))
import release_preflight as preflight  # noqa: E402


ASSERTIONS = 0


class CheckFailure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    global ASSERTIONS
    if not condition:
        raise CheckFailure(message)
    ASSERTIONS += 1


def tree_digest(root: Path, *, workspace: bool = False) -> str:
    if not os.path.lexists(root):
        return hashlib.sha256(b"absent\n").hexdigest()
    digest = hashlib.sha256()
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        if workspace:
            directories[:] = [name for name in directories if name not in {".git", ".build", "node_modules", ".output", "DerivedData", "__pycache__"}]
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        for name in ["."] + directories + files:
            path = Path(current) if name == "." else Path(current) / name
            info = path.lstat()
            relative = path.relative_to(root).as_posix() if path != root else "."
            digest.update(f"{relative}\0{stat.S_IFMT(info.st_mode)}\0{stat.S_IMODE(info.st_mode)}\0{info.st_size}\0{info.st_mtime_ns}\n".encode())
            if stat.S_ISREG(info.st_mode):
                digest.update(path.read_bytes())
    return digest.hexdigest()


def run(args: list[str], *, env: dict[str, str], expected: int) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run([sys.executable, str(SCRIPT), *args], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != expected:
        raise CheckFailure(f"expected exit {expected}, got {result.returncode}: {args}\n{result.stdout.decode(errors='replace')}{result.stderr.decode(errors='replace')}")
    return result


def base_config() -> dict:
    return preflight.stable_host.load_config(ROOT)


def base_policy() -> dict:
    return preflight.load_policy(ROOT)


def ready_inputs() -> tuple[dict, dict, dict, dict, list[dict]]:
    config = base_config()
    config["releaseExtensionIDs"] = ["a" * 32]
    config["releaseExtensionIDsStatus"] = "frozen"
    policy = base_policy()
    policy["teamIDStatus"] = "frozen"
    policy["teamID"] = "ABCDE12345"
    artifact = {"artifact": "present", "signature": "developer-id", "hardenedRuntime": "present", "team": "match", "notarization": "present", "stapling": "present"}
    targets = preflight.planned_targets(policy, ["chrome", "brave", "edge"], "default")
    return config, policy, artifact, {"state": "verified"}, targets


def assert_policy_schema(audit: Path) -> None:
    policy_path = audit / "config/native-host-release-policy.json"
    policy_path.parent.mkdir(mode=0o700)
    shutil.copy2(ROOT / "config/native-host-release-policy.json", policy_path)
    check(preflight.load_policy(audit)["formatVersion"] == 1, "frozen policy did not load")
    value = json.loads(policy_path.read_text(encoding="utf-8"))
    value["unknown"] = True
    policy_path.write_text(json.dumps(value), encoding="utf-8")
    try:
        preflight.load_policy(audit)
    except preflight.PreflightError as error:
        check("keys" in str(error), "unknown policy field was not rejected precisely")
    else:
        raise CheckFailure("unknown policy field was accepted")
    base = json.loads((ROOT / "config/native-host-release-policy.json").read_text(encoding="utf-8"))
    mutations = [
        (("formatVersion",), []),
        (("installAuthorization",), []),
        (("distribution",), []),
        (("browserTargets",), []),
        (("browserTargets", "brave"), []),
        (("browserTargets", "chrome"), []),
        (("browserTargets", "edge"), []),
        (("browserTargets", "brave", "browser"), []),
        (("teamIDStatus",), []),
        (("teamID",), []),
    ]
    for path, replacement in mutations:
        mutated = json.loads(json.dumps(base))
        cursor = mutated
        for key in path[:-1]:
            cursor = cursor[key]
        cursor[path[-1]] = replacement
        policy_path.write_text(json.dumps(mutated), encoding="utf-8")
        try:
            preflight.load_policy(audit)
        except preflight.PreflightError:
            check(True, f"policy type drift rejected: {'.'.join(path)}")
        else:
            raise CheckFailure(f"policy type drift accepted: {'.'.join(path)}")
    frozen_team = json.loads(json.dumps(base))
    frozen_team["teamIDStatus"] = "frozen"
    frozen_team["teamID"] = []
    policy_path.write_text(json.dumps(frozen_team), encoding="utf-8")
    try:
        preflight.load_policy(audit)
    except preflight.PreflightError:
        check(True, "frozen Team ID type drift rejected")
    else:
        raise CheckFailure("frozen Team ID type drift accepted")


def assert_apple_query_boundary(audit: Path) -> None:
    artifact = audit / "fixture.dmg"
    app = audit / "Fixture.app"
    artifact.write_bytes(b"fixture")
    app.mkdir(mode=0o700)
    calls: list[tuple[list[str], dict]] = []

    def fake_runner(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append((command, kwargs))
        if command[:2] == ["/usr/bin/codesign", "--verify"]:
            return subprocess.CompletedProcess(command, 0, "", "")
        if command == ["/usr/bin/codesign", "-dvv", str(app)]:
            return subprocess.CompletedProcess(command, 0, "Authority=Developer ID Application: Example\nflags=0x10000(runtime)\nTeamIdentifier=ABCDE12345\n", "")
        if command == [
            "/usr/sbin/spctl",
            "-a",
            "-vv",
            "--type",
            "open",
            "--ignore-cache",
            "--no-cache",
            str(artifact),
        ]:
            return subprocess.CompletedProcess(command, 0, f"{artifact}: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example\n", "")
        if command == ["/usr/bin/xcrun", "stapler", "validate", str(artifact)]:
            return subprocess.CompletedProcess(command, 0, "", "")
        raise CheckFailure(f"unexpected Apple query argv: {command}")

    evidence = preflight.inspect_artifact(artifact, app, "ABCDE12345", runner=fake_runner)
    check(evidence == {"artifact": "present", "signature": "developer-id", "hardenedRuntime": "present", "team": "match", "notarization": "present", "stapling": "present"}, "production artifact branch did not use strict fake Apple evidence")
    check(len(calls) == 4, "production artifact branch did not issue all four fixed queries")
    spctl_calls = [command for command, _ in calls if command and command[0] == "/usr/sbin/spctl"]
    check(
        spctl_calls
        == [[
            "/usr/sbin/spctl",
            "-a",
            "-vv",
            "--type",
            "open",
            "--ignore-cache",
            "--no-cache",
            str(artifact),
        ]],
        "spctl query must ignore existing cache and forbid cache writes",
    )
    for command, kwargs in calls:
        check(command[0] in {"/usr/bin/codesign", "/usr/sbin/spctl", "/usr/bin/xcrun"}, "Apple query escaped fixed executable set")
        check(kwargs["env"] == preflight.APPLE_QUERY_ENV, "Apple query inherited caller environment")
        check(kwargs["stdin"] is subprocess.DEVNULL, "Apple query did not use DEVNULL stdin")
        check(kwargs["timeout"] == preflight.APPLE_QUERY_TIMEOUT_SECONDS and kwargs["check"] is False and kwargs["text"] is True, "Apple query subprocess contract drifted")

    def timeout_runner(*_: object, **__: object) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired("fixed-query", preflight.APPLE_QUERY_TIMEOUT_SECONDS)

    def missing_runner(*_: object, **__: object) -> subprocess.CompletedProcess[str]:
        raise FileNotFoundError()

    check(preflight.run_readonly(["/usr/bin/codesign", "-dvv", str(app)], runner=timeout_runner) == (124, ""), "Apple timeout did not become missing evidence")
    check(preflight.run_readonly(["/usr/bin/codesign", "-dvv", str(app)], runner=missing_runner) == (127, ""), "missing Apple tool did not become missing evidence")
    check(preflight.run_readonly(["/bin/sh", "-c", "unsafe"], runner=fake_runner) == (126, ""), "non-fixed Apple query reached runner")

    good = "fixture.dmg: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example\n"
    check(preflight.notarization_from_spctl_text(good) == "present", "anchored notarization evidence rejected")
    for text in [
        "fixture-Notarized.dmg: accepted\nsource=Developer ID\norigin=Developer ID Application: Example\n",
        "source=Notarized Developer ID\nsource=Notarized Developer ID\norigin=Developer ID Application: Example\n",
        "source=Notarized Developer ID fake\norigin=Developer ID Application: Example\n",
        "source=Notarized Developer ID\norigin=Developer ID\n",
    ]:
        check(preflight.notarization_from_spctl_text(text) == "missing", "unanchored or duplicated spctl notarization evidence accepted")


def assert_lexical_paths(audit: Path) -> None:
    safe = audit / "safe.dmg"
    safe.write_bytes(b"fixture")
    invalid = ["", "/", "relative", str(safe) + "/", str(safe) + "/.", str(safe) + "/..", str(safe).replace("/private", "//private", 1), str(safe).replace("/", "/./", 1), str(safe) + "\nnext", str(safe) + "\rnext", str(safe) + "\x00next"]
    for raw in invalid:
        try:
            preflight.canonical_existing_path(raw, "--artifact-path", kind="file")
        except preflight.PreflightError as error:
            check(str(error) == "--artifact-path must be an existing canonical absolute path", "lexical path failure echoed unsafe input")
        else:
            raise CheckFailure("unsafe lexical path was accepted")


def assert_evaluator() -> None:
    config, policy, artifact, _, targets = ready_inputs()
    ready = preflight.evaluate_policy(config, policy, "verified", artifact, "owned", targets)
    check(ready["status"] == "READY", "pure policy evaluator cannot represent a fully evidenced policy combination")
    check(ready["blockers"] == [], "pure policy evaluator has blockers")
    check([target["browsers"] for target in ready["targets"]] == [["chrome", "brave"], ["edge"]], "Chrome/Brave shared target or Edge isolation drifted")
    for state, code in [
        ("missing", "package-missing"),
        ("invalid", "package-invalid"),
        ("unknown", "ownership-unknown"),
        ("malformed", "ownership-receipt-malformed"),
        ("conflict", "ownership-receipt-conflict"),
    ]:
        verdict = preflight.evaluate_policy(config, policy, state if state in {"missing", "invalid"} else "verified", artifact, state if state not in {"missing", "invalid"} else "owned", targets)
        check(any(item["code"] == code for item in verdict["blockers"]), f"{state} ownership/package blocker missing")
    for key, code in [("artifact", "distribution-artifact-invalid"), ("notarization", "notarization-missing"), ("stapling", "stapling-missing")]:
        broken_artifact = dict(artifact)
        broken_artifact[key] = "invalid" if key == "artifact" else "missing"
        verdict = preflight.evaluate_policy(config, policy, "verified", broken_artifact, "owned", targets)
        check(any(item["code"] == code for item in verdict["blockers"]), f"{key} evidence blocker missing")
    absent = preflight.evaluate_policy(config, policy, "verified", artifact, "absent", targets)
    check(absent["status"] == "READY" and absent["warnings"][0]["code"] == "ownership-receipt-absent", "absent ownership must warn without authorizing replacement")
    extension_drift_config = base_config()
    extension_drift_config["releaseExtensionIDs"] = []
    extension_drift_config["releaseExtensionIDsStatus"] = "not-frozen"
    extension_drift = preflight.evaluate_policy(extension_drift_config, policy, "verified", artifact, "owned", targets)
    check(any(item["code"] == "extension-ids-not-frozen" for item in extension_drift["blockers"]), "unfrozen extension IDs did not fail closed")
    policy_drift = base_policy()
    verdict = preflight.evaluate_policy(config, policy_drift, "verified", artifact, "owned", targets)
    check(any(item["code"] == "team-id-not-frozen" for item in verdict["blockers"]), "unfrozen Team ID did not fail closed")
    adhoc = preflight.evidence_from_text("Signature=adhoc\nflags=0x10000(runtime)\nTeamIdentifier=ABCDE12345", expected_team_id="ABCDE12345")
    check(adhoc["signature"] == "adhoc", "ad hoc signing evidence was not recognized")
    mismatch = preflight.evidence_from_text("Authority=Developer ID Application: Example\nflags=0x10000(runtime)\nTeamIdentifier=ABCDE12345", expected_team_id="ZZZZZ99999")
    check(mismatch == {"signature": "developer-id", "hardenedRuntime": "present", "team": "mismatch"}, "Developer ID/Team mismatch parsing drifted")
    missing_runtime = preflight.evidence_from_text("Authority=Developer ID Application: Example\nTeamIdentifier=ABCDE12345", expected_team_id="ABCDE12345")
    check(missing_runtime["hardenedRuntime"] == "missing", "missing hardened runtime was accepted")
    runtime_identifier = preflight.evidence_from_text("Authority=Developer ID Application: Example\nIdentifier=com.runtime.fake\nTeamIdentifier=ABCDE12345", expected_team_id="ABCDE12345")
    check(runtime_identifier["hardenedRuntime"] == "missing", "runtime text outside codesign flags was accepted")
    loose_authority = preflight.evidence_from_text("Identifier=Developer ID Application: fake\nflags=0x10000(runtime)\nTeamIdentifier=ABCDE12345", expected_team_id="ABCDE12345")
    check(loose_authority["signature"] == "missing-or-unrecognized", "non-Authority Developer ID text was accepted")
    loose_team = preflight.evidence_from_text("Authority=Developer ID Application: Example\nflags=0x10000(runtime)\nTeamIdentifier=ABCDE12345-not-a-team", expected_team_id="ABCDE12345")
    check(loose_team["team"] == "missing", "non-exact TeamIdentifier was accepted")
    production = preflight.add_production_binding_blockers(ready)
    check(production["status"] == "BLOCKED", "production report inherited synthetic policy READY")
    check({item["code"] for item in production["blockers"]} >= {"release-unit-binding-unverified", "target-ownership-unverified"}, "production binding blockers missing")
    try:
        preflight.planned_targets(policy, ["edge"], "Profile 1")
    except preflight.PreflightError:
        check(True, "custom Edge profile rejected")
    else:
        raise CheckFailure("custom Edge profile was accepted")


def assert_receipts(audit: Path) -> None:
    policy = base_policy()
    config = base_config()
    receipt = audit / "receipt.json"
    check(preflight.ownership_state(None, policy, config) == "absent", "absent receipt state drifted")
    receipt.write_text(json.dumps({"formatVersion": 1, "owner": "LinkDigest", "manifestRelativePaths": sorted({
        f"{target['manifestRelativePath']}/{config['hostName']}.json" for target in policy["browserTargets"].values()
    })}), encoding="utf-8")
    check(preflight.ownership_state(receipt, policy, config) == "owned", "owned receipt rejected")
    receipt.write_text("{}", encoding="utf-8")
    check(preflight.ownership_state(receipt, policy, config) == "malformed", "malformed receipt accepted")
    receipt.write_text(json.dumps({"formatVersion": 1, "owner": "LinkDigest", "manifestRelativePaths": ["Library/other.json"]}), encoding="utf-8")
    check(preflight.ownership_state(receipt, policy, config) == "conflict", "conflicting receipt accepted")


def assert_cli_and_side_effects(audit: Path) -> None:
    home = audit / "poison-home"
    tmpdir = audit / "poison-tmp"
    home.mkdir(mode=0o700)
    tmpdir.mkdir(mode=0o700)
    work_before = tree_digest(ROOT, workspace=True)
    home_before = tree_digest(home)
    tmp_before = tree_digest(tmpdir)
    bytecode_cache = ROOT / "scripts/native-host/__pycache__"
    bytecode_before = tree_digest(bytecode_cache)
    env = {key: value for key, value in os.environ.items() if key != "PYTHONDONTWRITEBYTECODE"}
    # Assembled at runtime so the snapshot secret scanner never sees a secret-shaped literal in source.
    fake_secret = "sk-" + "abcdefghijklmnopqrstuvwxyz0123456789"
    env.update({"HOME": str(home), "TMPDIR": str(tmpdir), "FAKE_SECRET": fake_secret})
    result = run(["report"], env=env, expected=10)
    value = json.loads(result.stdout)
    check(value["status"] == "BLOCKED", "current policy unexpectedly reports READY")
    check(value["separateAuthorizationRequired"] is True, "preflight did not preserve separate authorization")
    check(value["reportDigest"] == preflight.sha256_json({key: value[key] for key in value if key != "reportDigest"}), "report digest is not canonical")
    check(result.stdout == preflight.canonical_bytes(value), "CLI JSON is not canonical")
    check([item["code"] for item in value["blockers"]] == sorted(item["code"] for item in value["blockers"]), "blockers are not stable sorted")
    check(fake_secret.encode() not in result.stdout + result.stderr, "secret-shaped environment value leaked")
    check(tree_digest(ROOT, workspace=True) == work_before, "preflight CLI changed the worktree")
    check(tree_digest(home) == home_before, "preflight CLI changed poisoned HOME")
    check(tree_digest(tmpdir) == tmp_before, "preflight CLI changed poisoned TMPDIR")
    check(
        tree_digest(bytecode_cache) == bytecode_before,
        "preflight CLI changed the Python bytecode cache",
    )
    unsafe = run(["report", "--edge-profile", "Profile 1"], env=env, expected=2)
    check(b"non-default Edge profile" in unsafe.stderr, "unsafe Edge profile did not use exit 2")
    forged = run(["report", "--test-evidence", "ready"], env=env, expected=2)
    check(b"unrecognized arguments" in forged.stderr, "production CLI accepted forged test evidence")
    symlink = audit / "package-link"
    symlink.symlink_to(ROOT)
    unsafe = run(["report", "--package-root", str(symlink)], env=env, expected=2)
    check(b"symlink" in unsafe.stderr, "symlink package path did not fail closed")
    unsafe = run(["report", "--package-root", "relative-package"], env=env, expected=2)
    check(b"canonical absolute" in unsafe.stderr, "noncanonical package path did not fail closed")
    drift = audit / "package-drift"
    drift.mkdir(mode=0o700)
    unsafe = run(["report", "--package-root", str(drift)], env=env, expected=10)
    drift_report = json.loads(unsafe.stdout)
    check(drift_report["package"]["state"] == "invalid", "package drift was not reported as invalid")
    app_link = audit / "app-link"
    app_link.symlink_to(ROOT)
    unsafe = run(["report", "--app-path", str(app_link)], env=env, expected=2)
    check(b"symlink" in unsafe.stderr, "symlink app path did not fail closed")
    app = audit / "not-an-app"
    app.mkdir(mode=0o700)
    unsafe = run(["report", "--app-path", str(app)], env=env, expected=2)
    check(b".app suffix" in unsafe.stderr, "non-.app directory was accepted")
    artifact = audit / "not-a-dmg.zip"
    artifact.write_bytes(b"fixture")
    unsafe = run(["report", "--artifact-path", str(artifact)], env=env, expected=2)
    check(b".dmg suffix" in unsafe.stderr, "non-.dmg artifact was accepted")
    receipt = audit / "receipt-hardlink.json"
    receipt.write_text("{}", encoding="utf-8")
    receipt_link = audit / "receipt-hardlink-copy.json"
    os.link(receipt, receipt_link)
    unsafe = run(["report", "--ownership-receipt", str(receipt)], env=env, expected=2)
    check(b"single-link regular file" in unsafe.stderr, "hardlinked ownership receipt was accepted")
    safe_artifact = audit / "lexical.dmg"
    safe_artifact.write_bytes(b"fixture")
    for raw in [str(safe_artifact) + "/", str(safe_artifact) + "/.", str(safe_artifact).replace("/private", "//private", 1), str(safe_artifact) + "\nsecret"]:
        unsafe = run(["report", "--artifact-path", raw], env=env, expected=2)
        check(unsafe.stderr == b"release-preflight: --artifact-path must be an existing canonical absolute path\n", "CLI lexical path failure leaked raw input")


def main() -> int:
    audit = Path(tempfile.mkdtemp(prefix="linkdigest-release-preflight-audit.", dir="/private/tmp")).resolve()
    print("release-preflight-check: audit root is intentionally retained")
    print(f"RELEASE_PREFLIGHT_AUDIT_ROOT={audit}")
    try:
        assert_policy_schema(audit)
        assert_apple_query_boundary(audit)
        assert_lexical_paths(audit)
        assert_evaluator()
        assert_receipts(audit)
        assert_cli_and_side_effects(audit)
        print(f"release-preflight-check: PASS ({ASSERTIONS} assertions)")
        return 0
    except Exception as error:
        print(f"release-preflight-check: FAIL: {error}", file=sys.stderr)
        print(f"RELEASE_PREFLIGHT_AUDIT_ROOT={audit}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
