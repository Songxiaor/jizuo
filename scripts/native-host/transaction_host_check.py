#!/usr/bin/env python3
"""Fast /private/tmp gate for the r2 transaction host.

The check reuses one existing verified r1 package fixture and never builds a
Release package.  One named audit root is intentionally retained.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import select
import socket
import stat
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "scripts/native-host/transaction_host.py"
STABLE = ROOT / "scripts/native-host/stable_host.py"
LOCK_CONTENT = b"LinkDigest transaction lock v1\n"
SENTINEL_CONTENT = b"LinkDigest clean-room session v1\n"
EXTENSION_A = "a" * 32
EXTENSION_B = "b" * 32
ASSERTIONS = 0
SOCKET_COUNTER = 0


class CheckFailure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    global ASSERTIONS
    if not condition:
        raise CheckFailure(message)
    ASSERTIONS += 1


def run(
    command: list[str],
    *,
    env: dict[str, str],
    expected: int = 0,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != expected:
        raise CheckFailure(
            f"expected exit {expected}, got {result.returncode}: {' '.join(command)}\n"
            f"{result.stdout.decode(errors='replace')}{result.stderr.decode(errors='replace')}"
        )
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_digest(root: Path, *, workspace: bool = False) -> str:
    if not os.path.lexists(root):
        return hashlib.sha256(b"absent\n").hexdigest()
    digest = hashlib.sha256()
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        if workspace:
            directories[:] = [name for name in directories if name not in {".git", "__pycache__"}]
            files[:] = [name for name in files if name != "xcrun_db"]
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        for name in ["."] + directories + files:
            path = Path(current) if name == "." else Path(current) / name
            info = path.lstat()
            relative = path.relative_to(root).as_posix() if path != root else "."
            digest.update(
                f"{relative}\0{stat.S_IFMT(info.st_mode)}\0{stat.S_IMODE(info.st_mode)}\0"
                f"{info.st_uid}\0{info.st_gid}\0{info.st_nlink}\0{info.st_size}\0{info.st_mtime_ns}\n".encode()
            )
            if stat.S_ISREG(info.st_mode):
                digest.update(bytes.fromhex(sha256(path)))
            elif stat.S_ISLNK(info.st_mode):
                digest.update(os.readlink(path).encode())
    return digest.hexdigest()


def make_socket_leaf(path: Path) -> None:
    global SOCKET_COUNTER
    SOCKET_COUNTER += 1
    short = Path(f"/private/tmp/ldsock-{os.getpid()}-{SOCKET_COUNTER}")
    if os.path.lexists(short):
        short.unlink()
    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.bind(str(short))
    finally:
        sock.close()
    os.rename(short, path)


def locate_package(env: dict[str, str]) -> Path:
    explicit = os.environ.get("LINKDIGEST_TRANSACTION_PACKAGE")
    candidates = [Path(explicit)] if explicit else sorted(
        Path("/private/tmp").glob(
            "linkdigest-host-clean-room.audit.*/Moved Package 空格 μ/LinkDigestNativeHost-0.2.0-macos-arm64"
        )
    )
    for candidate in candidates:
        if not candidate.is_dir():
            continue
        result = subprocess.run(
            [sys.executable, str(STABLE), "verify-package", "--package-root", str(candidate)],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode == 0:
            return candidate.resolve()
    raise CheckFailure("no verified r1 package fixture is available; set LINKDIGEST_TRANSACTION_PACKAGE")


def make_v3(source: Path, destination: Path, env: dict[str, str]) -> None:
    shutil.copytree(source, destination, copy_function=shutil.copy2)
    metadata_path = destination / "package.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["productVersion"] = "0.3.0"
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    metadata_path.chmod(0o644)
    checksum_path = destination / "SHA256SUMS"
    lines = checksum_path.read_text(encoding="utf-8").splitlines()
    lines = [f"{sha256(metadata_path)}  package.json" if line.endswith("  package.json") else line for line in lines]
    checksum_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    checksum_path.chmod(0o644)
    result = run(
        [sys.executable, str(STABLE), "verify-package", "--package-root", str(destination)],
        env=env,
        expected=2,
    )
    check(b"metadata does not match" in result.stderr, "stable verifier accepted derived productVersion 0.3.0")


def make_session(audit: Path, name: str, lock_kind: str = "regular") -> tuple[Path, Path]:
    session = audit / f"linkdigest-host-clean-room.{name}"
    session.mkdir(mode=0o700)
    sentinel = session / ".linkdigest-clean-room-root"
    sentinel.write_bytes(SENTINEL_CONTENT)
    sentinel.chmod(0o600)
    lock = session / ".transaction.lock"
    if lock_kind == "regular":
        lock.write_bytes(LOCK_CONTENT)
        lock.chmod(0o600)
    elif lock_kind == "missing":
        pass
    elif lock_kind == "symlink":
        lock.symlink_to(sentinel)
    elif lock_kind == "hardlink":
        source = session / "lock-source"
        source.write_bytes(LOCK_CONTENT)
        source.chmod(0o600)
        os.link(source, lock)
    elif lock_kind == "fifo":
        os.mkfifo(lock, 0o600)
    elif lock_kind == "socket":
        make_socket_leaf(lock)
    elif lock_kind == "bad-mode":
        lock.write_bytes(LOCK_CONTENT)
        lock.chmod(0o644)
    elif lock_kind == "bad-bytes":
        lock.write_bytes(b"wrong\n")
        lock.chmod(0o600)
    else:
        raise AssertionError(lock_kind)
    home = session / "linkdigest-host-clean-room.home"
    home.mkdir(mode=0o700)
    return session, home


def mkdirs_0700(path: Path, boundary: Path) -> None:
    missing: list[Path] = []
    current = path
    while current != boundary and not current.exists():
        missing.append(current)
        current = current.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)


def base_inputs(action: str, session: Path, home: Path, package: Path | None = None) -> list[str]:
    values = ["--action", action, "--session-root", str(session), "--home-root", str(home)]
    if package is not None:
        values += [
            "--package-root",
            str(package),
            "--browser",
            "chrome",
            "--browser",
            "brave",
            "--browser",
            "edge",
            "--extension-id",
            EXTENSION_A,
        ]
    return values


def plan(action: str, session: Path, home: Path, package: Path | None, env: dict[str, str]) -> dict:
    result = run([sys.executable, str(HOST), "plan", *base_inputs(action, session, home, package)], env=env)
    return json.loads(result.stdout)


def apply(planned: dict, session: Path, home: Path, package: Path | None, env: dict[str, str], **extra: str) -> subprocess.CompletedProcess[bytes]:
    command = [
        sys.executable,
        str(HOST),
        "apply",
        *base_inputs(planned["action"], session, home, package),
        "--plan-digest",
        planned["planDigest"],
        "--confirm",
        planned["confirmation"],
    ]
    if extra.get("test_barriers"):
        command.append("--test-barriers")
    return run(command, env=env, expected=int(extra.get("expected", "0")))


def recover(session: Path, home: Path, env: dict[str, str], expected: int = 0) -> dict | None:
    result = run(
        [sys.executable, str(HOST), "recover", "--session-root", str(session), "--home-root", str(home)],
        env=env,
        expected=expected,
    )
    return json.loads(result.stdout) if expected == 0 else None


def installed_paths(home: Path) -> tuple[Path, Path, Path]:
    install = home / "Library/Application Support/LinkDigest/NativeMessagingHost"
    manifest = home / "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.syc.linkdigest.v01.json"
    return install, install / "receipt-v2.json", manifest


def default_manifest_paths(home: Path) -> tuple[Path, Path, Path]:
    host_name = "com.syc.linkdigest.v01.json"
    return (
        home / "Library/Application Support/Google/Chrome/NativeMessagingHosts" / host_name,
        home / "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts" / host_name,
        home / "Library/Application Support/Microsoft Edge/NativeMessagingHosts" / host_name,
    )


def install_initial(session: Path, home: Path, package: Path, env: dict[str, str]) -> dict:
    value = plan("install", session, home, package, env)
    check(value["operation"] == "initial-install", "initial plan operation drifted")
    check(
        {item["role"] for item in value["afterReceipt"]["ownedManifests"]}
        == {"chrome-default", "brave-default", "edge-default"},
        "initial plan collapsed independent browser manifest roles",
    )
    apply(value, session, home, package, env)
    _, receipt, _ = installed_paths(home)
    check(
        receipt.is_file() and all(path.is_file() for path in default_manifest_paths(home)),
        "initial install omitted receipt or an independent browser manifest",
    )
    return value


def assert_edge_overlap_rejected(
    session: Path,
    home: Path,
    package: Path,
    profile: Path,
    env: dict[str, str],
    label: str,
) -> None:
    safe = plan("install", session, home, package, env)
    unsafe_inputs = [
        "--action",
        "install",
        "--session-root",
        str(session),
        "--home-root",
        str(home),
        "--package-root",
        str(package),
        "--browser",
        "edge",
        "--edge-user-data-dir",
        str(profile),
        "--extension-id",
        EXTENSION_A,
    ]
    before = tree_digest(session)
    planned = run([sys.executable, str(HOST), "plan", *unsafe_inputs], env=env, expected=2)
    check(b"overlap" in planned.stderr, f"{label} plan rejection did not report overlap")
    run(
        [
            sys.executable,
            str(HOST),
            "apply",
            *unsafe_inputs,
            "--plan-digest",
            safe["planDigest"],
            "--confirm",
            safe["confirmation"],
        ],
        env=env,
        expected=2,
    )
    check(tree_digest(session) == before, f"{label} plan/apply rejection mutated the session")


def write_journal_fixture(home: Path, txid: str, plan_value: dict) -> Path:
    transaction = home / "Library/Application Support/LinkDigest/NativeMessagingHost/transactions" / txid
    mkdirs_0700(transaction, home)
    journal = {
        "formatVersion": 1,
        "phase": "prepared",
        "plan": plan_value,
        "txid": txid,
    }
    path = transaction / "journal.json"
    path.write_text(json.dumps(journal, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)
    return path


def mutate_leaf(path: Path, kind: str) -> None:
    if kind == "hardlink":
        peer = path.with_name(path.name + ".peer")
        os.link(path, peer)
        return
    path.unlink()
    if kind == "symlink":
        target = path.with_name(path.name + ".target")
        target.write_bytes(b"unknown\n")
        target.chmod(0o600)
        path.symlink_to(target)
    elif kind == "fifo":
        os.mkfifo(path, 0o600)
    elif kind == "socket":
        make_socket_leaf(path)
    else:
        raise AssertionError(kind)


def main() -> int:
    original_home = Path(os.environ["HOME"]).resolve()
    audit = Path(tempfile.mkdtemp(prefix="linkdigest-transaction-host-audit.", dir="/private/tmp")).resolve()
    audit.chmod(0o700)
    tool_home = audit / "tool-home"
    tool_home.mkdir(mode=0o700)
    env = {
        **os.environ,
        "HOME": str(tool_home),
        "TMPDIR": "/private/tmp",
        "PYTHONDONTWRITEBYTECODE": "1",
        "XDG_CACHE_HOME": str(audit / "cache"),
    }
    worktree_before = tree_digest(ROOT, workspace=True)
    real_home_root = original_home / "Library/Application Support/LinkDigest"
    real_home_before = tree_digest(real_home_root)
    print("transaction-host-check: audit root intentionally retained")
    print(f"TRANSACTION_AUDIT_ROOT={audit}")

    try:
        fixture = locate_package(env)
        package1 = audit / "package-v1"
        package2 = audit / "package-v2"
        shutil.copytree(fixture, package1, copy_function=shutil.copy2)
        run([sys.executable, str(STABLE), "verify-package", "--package-root", str(package1)], env=env)
        make_v3(package1, package2, env)
        check(True, "one current fixture and transaction-only v3 package prepared")

        session_edge_ok, home_edge_ok = make_session(audit, "edge-positive")
        default_edge = run(
            [
                sys.executable,
                str(HOST),
                "plan",
                "--action",
                "install",
                "--session-root",
                str(session_edge_ok),
                "--home-root",
                str(home_edge_ok),
                "--package-root",
                str(package1),
                "--browser",
                "chrome",
                "--browser",
                "brave",
                "--browser",
                "edge",
                "--extension-id",
                EXTENSION_A,
            ],
            env=env,
        )
        default_edge_plan = json.loads(default_edge.stdout)
        check(
            len(default_edge_plan["afterReceipt"]["ownedManifests"]) == 3,
            "default Chrome, Brave, and Edge targets were not independent",
        )
        check(
            {item["role"] for item in default_edge_plan["afterReceipt"]["ownedManifests"]}
            == {"chrome-default", "brave-default", "edge-default"},
            "default browser manifest roles were not the exact independent set",
        )
        independent_profile = session_edge_ok / "isolated-edge-profile"
        independent_profile.mkdir(mode=0o700)
        independent_edge = run(
            [
                sys.executable,
                str(HOST),
                "plan",
                "--action",
                "install",
                "--session-root",
                str(session_edge_ok),
                "--home-root",
                str(home_edge_ok),
                "--package-root",
                str(package1),
                "--browser",
                "edge",
                "--edge-user-data-dir",
                str(independent_profile),
                "--extension-id",
                EXTENSION_A,
            ],
            env=env,
        )
        independent_edge_plan = json.loads(independent_edge.stdout)
        check(
            independent_edge_plan["afterReceipt"]["ownedManifests"][0]["role"] == "edge-profile",
            "independent Edge profile was not allowed",
        )

        session_r1_v2, home_r1_v2 = make_session(audit, "r1-v2-reject")
        before_r1_v2 = tree_digest(session_r1_v2)
        run(
            [
                sys.executable,
                str(STABLE),
                "clean-room-install",
                "--package-root",
                str(package2),
                "--session-root",
                str(session_r1_v2),
                "--home-root",
                str(home_r1_v2),
                "--browser",
                "chrome",
                "--extension-id",
                EXTENSION_A,
                "--apply",
            ],
            env=env,
            expected=2,
        )
        check(tree_digest(session_r1_v2) == before_r1_v2, "r1 installer mutated state for a 0.2.0 package")

        hardlink_package = audit / "package-hardlink"
        shutil.copytree(package1, hardlink_package, copy_function=shutil.copy2)
        os.link(hardlink_package / "package.json", hardlink_package / "package.json.peer")
        result = subprocess.run(
            [sys.executable, str(STABLE), "verify-package", "--package-root", str(hardlink_package)],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        check(result.returncode == 2 and b"owner/link-count" in result.stderr, "package hardlink was accepted")

        for kind in ("missing", "symlink", "hardlink", "fifo", "socket", "bad-mode", "bad-bytes"):
            session, home = make_session(audit, f"lock-{kind}", kind)
            before = tree_digest(session)
            result = run(
                [sys.executable, str(HOST), "plan", *base_inputs("install", session, home, package1)],
                env=env,
                expected=2,
            )
            check(b"lock" in result.stderr, f"{kind} lock failure was not typed")
            check(tree_digest(session) == before, f"{kind} lock rejection mutated the session")

        session, home = make_session(audit, "stale")
        first_plan = plan("install", session, home, package1, env)
        before = tree_digest(session)
        stale_command = [
            sys.executable,
            str(HOST),
            "apply",
            "--action",
            "install",
            "--session-root",
            str(session),
            "--home-root",
            str(home),
            "--package-root",
            str(package1),
            "--browser",
            "chrome",
            "--extension-id",
            EXTENSION_B,
            "--plan-digest",
            first_plan["planDigest"],
            "--confirm",
            first_plan["confirmation"],
        ]
        run(stale_command, env=env, expected=4)
        check(tree_digest(session) == before, "stale plan rejection changed the session tree")

        lock_fd = os.open(session / ".transaction.lock", os.O_RDWR)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            before = tree_digest(session)
            apply(first_plan, session, home, package1, env, expected="3")
            check(tree_digest(session) == before, "lock-busy rejection mutated the session")
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
        apply(first_plan, session, home, package1, env)
        check(json.loads(installed_paths(home)[1].read_text())["current"]["version"] == "0.2.0", "initial receipt version drifted")
        install_root = installed_paths(home)[0]
        current_version = install_root / "versions/0.2.0-macos-arm64"
        assert_edge_overlap_rejected(session, home, package1, current_version, env, "current version Edge profile")
        install_profile = install_root / "edge-profile"
        install_profile.mkdir(mode=0o700)
        assert_edge_overlap_rejected(session, home, package1, install_profile, env, "install descendant Edge profile")

        session_package, home_package = make_session(audit, "edge-package-overlap")
        package_inside = session_package / "package-v1"
        shutil.copytree(package1, package_inside, copy_function=shutil.copy2)
        install_initial(session_package, home_package, package_inside, env)
        assert_edge_overlap_rejected(session_package, home_package, package_inside, package_inside, env, "package-root Edge profile")
        assert_edge_overlap_rejected(
            session_package,
            home_package,
            package_inside,
            package_inside / "LinkDigest_LinkDigestCore.bundle",
            env,
            "package-descendant Edge profile",
        )

        session_anchor, home_anchor = make_session(audit, "anchor-replacement")
        anchor_plan = plan("install", session_anchor, home_anchor, package1, env)
        notify_read, notify_write = os.pipe()
        release_read, release_write = os.pipe()
        anchor_env = {
            **env,
            "LINKDIGEST_TEST_BARRIER": "lock_acquired",
            "LINKDIGEST_TEST_BARRIER_ACTION": "wait",
            "LINKDIGEST_TEST_BARRIER_FD": str(notify_write),
            "LINKDIGEST_TEST_RELEASE_FD": str(release_read),
        }
        anchor_command = [
            sys.executable,
            str(HOST),
            "apply",
            *base_inputs("install", session_anchor, home_anchor, package1),
            "--plan-digest",
            anchor_plan["planDigest"],
            "--confirm",
            anchor_plan["confirmation"],
            "--test-barriers",
        ]
        process = subprocess.Popen(
            anchor_command,
            cwd=ROOT,
            env=anchor_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=(notify_write, release_read),
        )
        os.close(notify_write)
        os.close(release_read)
        try:
            ready, _, _ = select.select([notify_read], [], [], 10)
            check(bool(ready) and os.read(notify_read, 128) == b"lock_acquired\n", "anchor barrier did not notify")
            moved_anchor = session_anchor.with_name(session_anchor.name + ".moved")
            os.rename(session_anchor, moved_anchor)
            session_anchor.mkdir(mode=0o700)
            (session_anchor / ".linkdigest-clean-room-root").write_bytes(SENTINEL_CONTENT)
            (session_anchor / ".linkdigest-clean-room-root").chmod(0o600)
            (session_anchor / ".transaction.lock").write_bytes(LOCK_CONTENT)
            (session_anchor / ".transaction.lock").chmod(0o600)
            (session_anchor / home_anchor.name).mkdir(mode=0o700)
            os.write(release_write, b"1")
            stdout, stderr = process.communicate(timeout=10)
            check(process.returncode == 8, f"replaced session anchor was not rejected: {stdout!r} {stderr!r}")
            check(
                not (moved_anchor / home_anchor.name / "Library/Application Support/LinkDigest").exists(),
                "session anchor replacement allowed an anchored mutation",
            )
        finally:
            os.close(notify_read)
            os.close(release_write)
            if process.poll() is None:
                process.kill()
                process.wait()

        session_drift, home_drift = make_session(audit, "manifest-drift")
        install_initial(session_drift, home_drift, package1, env)
        manifest = installed_paths(home_drift)[2]
        manifest.write_bytes(manifest.read_bytes() + b"modified")
        manifest.chmod(0o600)
        before = tree_digest(session_drift)
        run(
            [sys.executable, str(HOST), "plan", *base_inputs("uninstall", session_drift, home_drift)],
            env=env,
            expected=6,
        )
        check(tree_digest(session_drift) == before, "modified manifest rejection mutated state")

        session_migrate, home_migrate = make_session(audit, "migrate-upgrade-uninstall")
        run(
            [
                sys.executable,
                str(STABLE),
                "clean-room-install",
                "--package-root",
                str(package1),
                "--session-root",
                str(session_migrate),
                "--home-root",
                str(home_migrate),
                "--browser",
                "chrome",
                "--extension-id",
                EXTENSION_A,
                "--apply",
            ],
            env=env,
        )
        migration = plan("install", session_migrate, home_migrate, package1, env)
        check(migration["operation"] == "migrate-v1", "v1 migration was not planned")
        apply(migration, session_migrate, home_migrate, package1, env)
        install, receipt, _ = installed_paths(home_migrate)
        check(receipt.is_file() and not (install / "receipt-v1.json").exists(), "v1 receipt did not migrate")
        upgrade = plan("upgrade", session_migrate, home_migrate, package2, env)
        apply(upgrade, session_migrate, home_migrate, package2, env)
        upgraded = json.loads(receipt.read_text())
        check(upgraded["current"]["version"] == "0.3.0", "upgrade did not select v3")
        check([item["version"] for item in upgraded["lineage"]] == ["0.2.0"], "upgrade lineage drifted")
        protected = home_migrate / "Library/Application Support/LinkDigest/history.sqlite"
        exported = home_migrate / "Library/Application Support/LinkDigest/exports/keep.md"
        sibling = install / "do-not-delete.txt"
        exported.parent.mkdir(mode=0o700)
        protected.write_bytes(b"history")
        exported.write_bytes(b"export")
        sibling.write_bytes(b"sibling")
        for path in (protected, exported, sibling):
            path.chmod(0o600)
        uninstall = plan("uninstall", session_migrate, home_migrate, None, env)
        apply(uninstall, session_migrate, home_migrate, None, env)
        check(all(path.is_file() for path in (protected, exported, sibling)), "uninstall deleted unowned data")
        check(recover(session_migrate, home_migrate, env)["result"] == "noop", "post-uninstall recover was not noop")

        session_exception, home_exception = make_session(audit, "normal-rollback")
        install_initial(session_exception, home_exception, package1, env)
        _, receipt, _ = installed_paths(home_exception)
        receipt_gid = receipt.stat().st_gid
        upgrade = plan("upgrade", session_exception, home_exception, package2, env)
        barrier_env = {**env, "LINKDIGEST_TEST_BARRIER": "before_receipt_commit", "LINKDIGEST_TEST_BARRIER_ACTION": "error"}
        apply(upgrade, session_exception, home_exception, package2, barrier_env, expected="7", test_barriers="1")
        check(json.loads(receipt.read_text())["current"]["version"] == "0.2.0", "normal exception did not roll back")
        check(receipt.stat().st_gid == receipt_gid, "receipt gid changed across rollback")

        for barrier in ("journal_durable", "version_published", "before_receipt_commit", "after_receipt_commit"):
            session_kill, home_kill = make_session(audit, f"kill-{barrier}")
            install_initial(session_kill, home_kill, package1, env)
            planned = plan("upgrade", session_kill, home_kill, package2, env)
            kill_env = {**env, "LINKDIGEST_TEST_BARRIER": barrier, "LINKDIGEST_TEST_BARRIER_ACTION": "sigkill"}
            command = [
                sys.executable,
                str(HOST),
                "apply",
                *base_inputs("upgrade", session_kill, home_kill, package2),
                "--plan-digest",
                planned["planDigest"],
                "--confirm",
                planned["confirmation"],
                "--test-barriers",
            ]
            result = subprocess.run(command, cwd=ROOT, env=kill_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            check(result.returncode == -9, f"{barrier} did not SIGKILL")
            recovered = recover(session_kill, home_kill, env)
            version = json.loads(installed_paths(home_kill)[1].read_text())["current"]["version"]
            expected_version = "0.3.0" if barrier == "after_receipt_commit" else "0.2.0"
            check(version == expected_version, f"{barrier} recovered to {version}")
            check(recovered["result"] in {"rolled-back", "finalized"}, f"{barrier} recovery result drifted")

        session_scaffold, home_scaffold = make_session(audit, "scaffold")
        scaffold = home_scaffold / "Library/Application Support/LinkDigest/NativeMessagingHost/transactions" / ("1" * 32)
        mkdirs_0700(scaffold / "staged", home_scaffold)
        mkdirs_0700(scaffold / "backups/manifests", home_scaffold)
        (scaffold / "backups/versions").mkdir(mode=0o700)
        planned_command = [sys.executable, str(HOST), "plan", *base_inputs("install", session_scaffold, home_scaffold, package1)]
        run(planned_command, env=env, expected=5)
        check(recover(session_scaffold, home_scaffold, env)["result"] == "scaffold-cleaned", "safe scaffold was not cleaned")
        check(recover(session_scaffold, home_scaffold, env)["result"] == "noop", "second scaffold recover was not noop")
        unknown = scaffold.parent / ("2" * 32)
        unknown.mkdir(mode=0o700)
        (unknown / "unknown").write_bytes(b"keep")
        recover(session_scaffold, home_scaffold, env, expected=8)
        check((unknown / "unknown").is_file(), "unsafe scaffold content was deleted")

        journal_mutations = {
            "empty-plan": lambda body: {},
            "unknown-field": lambda body: body | {"unknown": True},
            "wrong-roots": lambda body: body | {"sessionRoot": "/private/tmp/wrong-session"},
            "bad-operation": lambda body: body | {"operation": "uninstall"},
            "bad-payload-coverage": lambda body: body | {"manifestPayloads": []},
        }
        for index, (label, mutate) in enumerate(journal_mutations.items(), start=3):
            session_journal, home_journal = make_session(audit, f"journal-{label}")
            planned = plan("install", session_journal, home_journal, package1, env)
            body = {key: value for key, value in planned.items() if key not in {"confirmation", "planDigest"}}
            malformed = mutate(json.loads(json.dumps(body)))
            journal_path = write_journal_fixture(home_journal, f"{index:032x}", malformed)
            before = tree_digest(session_journal)
            recover(session_journal, home_journal, env, expected=8)
            check(tree_digest(session_journal) == before, f"{label} journal recovery mutated the session")
            check(journal_path.is_file(), f"{label} malformed journal was not preserved")

        session_poison, home_poison = make_session(audit, "poison-tmpdir")
        poison_before = tree_digest(ROOT, workspace=True)
        poison_env = {**env, "TMPDIR": str(ROOT)}
        check(plan("install", session_poison, home_poison, package1, poison_env)["operation"] == "initial-install", "poison TMPDIR diverted plan")
        check(tree_digest(ROOT, workspace=True) == poison_before, "poison TMPDIR changed worktree")

        for category in ("receipt", "manifest"):
            for kind in ("symlink", "hardlink", "fifo", "socket"):
                session_leaf, home_leaf = make_session(audit, f"{category}-{kind}")
                install_initial(session_leaf, home_leaf, package1, env)
                _, receipt_leaf, manifest_leaf = installed_paths(home_leaf)
                mutate_leaf(receipt_leaf if category == "receipt" else manifest_leaf, kind)
                result = subprocess.run(
                    [sys.executable, str(HOST), "plan", *base_inputs("uninstall", session_leaf, home_leaf)],
                    cwd=ROOT,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                check(result.returncode in {2, 6, 8}, f"{category} {kind} was accepted")

        check(tree_digest(real_home_root) == real_home_before, "real HOME LinkDigest metadata changed")
        check(tree_digest(ROOT, workspace=True) == worktree_before, "worktree changed during quick gate")
        print(f"transaction-host-check: real HOME unchanged ({real_home_before})")
        print(f"transaction-host-check: PASS ({ASSERTIONS} assertions)")
        print(f"TRANSACTION_AUDIT_ROOT={audit}")
        return 0
    except BaseException as error:
        print(f"transaction-host-check: FAIL: {error}", file=sys.stderr)
        traceback.print_exc()
        print(f"TRANSACTION_AUDIT_ROOT={audit}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
