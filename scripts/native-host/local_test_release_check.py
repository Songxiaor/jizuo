#!/usr/bin/env python3
"""Deterministic independent-review gate for an immutable r4b audit."""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

sys.dont_write_bytecode = True

import local_test_release as local
import release_unit as r4a
import stable_host


TESTS = 0


PRD_VALUE_METRICS = (
    ("首次价值时间", "安装与模型配置完成后，5 分钟内完成第一条总结", "新用户观察测试", "从“安装与模型配置均完成”的时刻开始计时，到第一条总结完成；安装耗时与模型配置耗时另行记录，不计入首次价值时间。"),
    ("固定样本任务完成率", "≥ 90%", "20 条普通文章测试集", "使用 20 条普通文章测试集，逐条记录捕获→总结是否完成；完成率 = 完成条数 / 20。"),
    ("当前页正文可用率", "≥ 80%", "人工核对标题、主体和结尾", "逐条人工核对标题、主体和结尾是否足以支持摘要；可用率 = 可用条数 / 样本数。"),
    ("失败恢复率", "≥ 70%", "测试用户按提示完成重试", "测试用户遇到可恢复失败后按 App 提示完成重试；恢复率 = 成功重试次数 / 尝试重试次数。"),
    ("7 日复用", "早期测试用户一周内再次处理链接", "本地访谈记录，不默认上传遥测", "首次使用后 7 日内人工回访或自测，记录是否再次处理链接及使用场景；使用本地访谈记录，不默认上传遥测。"),
)


class CheckFailure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    global TESTS
    TESTS += 1
    if not condition:
        raise CheckFailure(message)


def required_key(mapping: dict[str, Any], key: str, label: str) -> Any:
    if key not in mapping:
        raise CheckFailure(f"{label} is missing required key: {key}")
    return mapping[key]


def expect_local(action: Callable[[], Any], code: int, message: str) -> None:
    try:
        action()
    except local.LocalTestError as error:
        check(error.code == code, message)
        return
    raise CheckFailure(f"expected LocalTestError: {message}")


def validate_new_review_root(value: str) -> Path:
    return local.validate_new_named_root(value, local.REVIEW_PREFIX, "--review-root")


def canonical_checks(
    audit: Path,
    candidate: Path,
    config: dict[str, Any],
    extension_identity: dict[str, str | int],
) -> tuple[dict[str, Any], dict[str, Any]]:
    report = local.load_json(audit / "r4b-engineering-report.json", "r4b engineering report")
    check(local.canonical_bytes(report) == (audit / "r4b-engineering-report.json").read_bytes(), "engineering report canonical")
    check(report["engineeringStatus"] == "implementation-candidate", "implementation candidate status")
    check(report["manualTestStatus"] == "READY_FOR_MANUAL_OPEN-candidate", "manual open candidate status")
    check(report["productStatus"] == "BLOCKED" and report["publicReleaseStatus"] == "BLOCKED", "product/public blocked")
    check(report["reviewStatus"] == "PENDING_INDEPENDENT_REVIEW", "review pending before gate")
    configured = config["browserExtension"]
    records, digest = local.validate_handoff_tree(
        candidate,
        config,
        {
            "artifact": {"handoffPath": f"{configured['handoffDirectory']}/{extension_identity['artifactName']}"},
            "manifestTemplates": {
                browser: {"handoffPath": f"{configured['handoffDirectory']}/native-host-manifests/{browser}.json"}
                for browser in local.extension_artifact.TEMPLATE_BROWSERS
            },
        },
    )
    check(digest == report["candidateDigest"], "candidate tree digest binding")
    check(records == report["candidateRecords"], "candidate tree records binding")
    manifest = local.load_json(candidate / "BUILD_MANIFEST.json", "build manifest")
    check(local.canonical_bytes(manifest) == (candidate / "BUILD_MANIFEST.json").read_bytes(), "build manifest canonical")
    check(manifest["distributionClass"] == "local-test-ad-hoc", "distribution class")
    check(manifest["manualTestStatus"] == "READY_FOR_MANUAL_OPEN", "manifest manual status")
    check(manifest["productStatus"] == "BLOCKED" and manifest["publicReleaseStatus"] == "BLOCKED", "manifest blocked")
    check(manifest["gitUsed"] is True and manifest["build"]["gitUsed"] is False, "Git used only for source selection")
    check(manifest["build"]["networkFallback"] is False, "no build network fallback")
    expected_payload_paths = local.expected_handoff_paths(
        config,
        {
            "artifact": {"handoffPath": f"{configured['handoffDirectory']}/{extension_identity['artifactName']}"},
            "manifestTemplates": {
                browser: {"handoffPath": f"{configured['handoffDirectory']}/native-host-manifests/{browser}.json"}
                for browser in local.extension_artifact.TEMPLATE_BROWSERS
            },
        },
    ) - {"BUILD_MANIFEST.json", "SHA256SUMS"}
    check(set(manifest["payloadHashesBeforeManifest"]) == expected_payload_paths, "payload hash paths are exact")
    for relative, expected in manifest["payloadHashesBeforeManifest"].items():
        check(local.sha256_file(candidate / relative) == expected, f"payload hash {relative}")
    check(local.sha256_file(candidate / config["dmgName"]) == manifest["dmg"]["dmgHash"], "DMG hash binding")
    return report, manifest


def source_archive_checks(
    candidate: Path,
    review: Path,
    config: dict[str, Any],
    build_manifest: dict[str, Any],
) -> tuple[Path, Path, dict[str, Any]]:
    source_dir = candidate / "source"
    manifest_path = source_dir / local.SOURCE_MANIFEST
    source_manifest = local.load_json(manifest_path, "source manifest")
    check(local.canonical_bytes(source_manifest) == manifest_path.read_bytes(), "source manifest canonical")
    check(local.sha256_file(manifest_path) == build_manifest["source"]["manifestHash"], "source manifest/build manifest hash binding")
    source_archive = source_dir / config["sourceArchive"]
    dependency_archive = source_dir / config["grdbArchive"]
    check(local.sha256_file(source_archive) == source_manifest["source"]["archiveHash"], "source archive hash")
    check(local.sha256_file(dependency_archive) == source_manifest["dependency"]["archiveHash"], "dependency archive hash")
    check(source_manifest["source"]["archiveHash"] == build_manifest["source"]["sourceArchiveHash"], "source archive/build manifest binding")
    check(source_manifest["dependency"]["archiveHash"] == build_manifest["source"]["dependencyArchiveHash"], "dependency archive/build manifest binding")
    source = local.extract_safe_tar_gz(source_archive, config["sourceTreeName"], review / "source-extracted")
    dependency = local.extract_safe_tar_gz(dependency_archive, "GRDB.swift-7.11.1", review / "dependency-extracted")
    check(local.portable_tree_records(source)[1] == source_manifest["source"]["treeDigest"], "source archive roundtrip")
    check(local.portable_tree_records(dependency)[1] == source_manifest["dependency"]["treeDigest"], "dependency archive roundtrip")
    check(local.sha256_file(dependency / "LICENSE") == source_manifest["dependency"]["licenseHash"], "GRDB LICENSE preserved")
    first = review / "determinism/source.first.tar.gz"
    second = review / "determinism/source.second.tar.gz"
    first.parent.mkdir(mode=0o700)
    hash_one = local.deterministic_tar_gz(source, config["sourceTreeName"], first)
    hash_two = local.deterministic_tar_gz(source, config["sourceTreeName"], second)
    check(hash_one == hash_two == source_manifest["source"]["archiveHash"], "source tar.gz deterministic twice")
    dep_one = review / "determinism/dependency.first.tar.gz"
    dep_two = review / "determinism/dependency.second.tar.gz"
    dep_hash_one = local.deterministic_tar_gz(dependency, "GRDB.swift-7.11.1", dep_one)
    dep_hash_two = local.deterministic_tar_gz(dependency, "GRDB.swift-7.11.1", dep_two)
    check(dep_hash_one == dep_hash_two == source_manifest["dependency"]["archiveHash"], "dependency tar.gz deterministic twice")
    scan_source = local.scan_secret_tree(
        source, "review source", config["secretFixtureHashAllowlist"]
    )
    scan_dependency = local.scan_secret_tree(dependency, "review dependency")
    check(scan_source == source_manifest["source"]["secretScan"], "source secret scan binding")
    check(scan_dependency == source_manifest["dependency"]["secretScan"], "dependency secret scan binding")
    return source, dependency, source_manifest


def extension_artifact_checks(
    candidate: Path,
    source: Path,
    review: Path,
    manifest: dict[str, Any],
    source_manifest: dict[str, Any],
    config: dict[str, Any],
) -> dict[str, Any]:
    configured = config["browserExtension"]
    source_records = required_key(required_key(source_manifest, "source", "source manifest"), "records", "source manifest source")
    artifact_records = [
        record
        for record in source_records
        if record["type"] == "file"
        and re.fullmatch(r"apps/browser-extension/identity-artifact/LinkDigest-extension-[^/]+-chromium\.zip", record["path"])
    ]
    check(len(artifact_records) == 1, "source manifest has exactly one versioned extension ZIP")
    check(
        artifact_records[0]["path"] == configured["artifactSource"],
        "source manifest extension ZIP path equals frozen configuration",
    )
    facts = local.extension_artifact_facts(source, config)
    identity = local.extension_artifact.load_identity(source)
    display = local.extension_artifact.load_display(source)
    source_artifact = source / facts["artifact"]["sourcePath"]
    candidate_artifact = candidate / facts["artifact"]["handoffPath"]
    check(local.sha256_file(source_artifact) == facts["artifact"]["sha256"], "source extension artifact hash")
    check(local.sha256_file(candidate_artifact) == facts["artifact"]["sha256"], "candidate extension artifact hash")
    check(local.extension_artifact.verify_zip(candidate_artifact, identity, display) == facts["zipEntries"], "candidate extension artifact manifest and ZIP metadata")
    check(facts["version"] == configured["version"], "extension artifact manifest version equals frozen configuration")
    template_hashes = local.extension_artifact.verify_templates(
        source,
        identity,
        local.extension_artifact.validate_native_host_binding(source, identity),
        candidate / "extension" / "native-host-manifests",
    )
    check(
        template_hashes == {browser: value["sha256"] for browser, value in facts["manifestTemplates"].items()},
        "Chrome/Brave/Edge template hashes",
    )
    check(required_key(manifest, "browserExtension", "build manifest") == facts, "build manifest extension binding")
    extracted = local.extension_artifact.extract_verified_zip(
        source_artifact,
        review / "determinism/extension-extracted",
        identity,
        display,
    )
    first = review / "determinism/extension.first.zip"
    second = review / "determinism/extension.second.zip"
    first_hash = local.extension_artifact.deterministic_zip(extracted, first)
    second_hash = local.extension_artifact.deterministic_zip(extracted, second)
    check(first_hash == second_hash == facts["artifact"]["sha256"], "extension ZIP deterministic twice")
    check(first.read_bytes() == second.read_bytes() == source_artifact.read_bytes(), "extension ZIP byte-identical twice")
    for relative in [
        facts["artifact"]["sourcePath"],
        facts["identity"]["sourcePath"],
        *(template["sourcePath"] for template in facts["manifestTemplates"].values()),
    ]:
        matches = [record for record in source_records if record["path"] == relative and record["type"] == "file"]
        check(len(matches) == 1, f"source manifest has one extension record: {relative}")
        record_hash = required_key(matches[0], "hash", f"source manifest extension record: {relative}")
        check(record_hash == local.sha256_file(source / relative), f"source manifest extension hash: {relative}")
    return facts


def acceptance_guide_checks(
    candidate: Path,
    source: Path,
    manifest: dict[str, Any],
    source_manifest: dict[str, Any],
    config: dict[str, Any],
) -> None:
    expected = {
        "sourcePath": config["acceptanceGuideSource"],
        "sha256": local.sha256_file(source / config["acceptanceGuideSource"]),
    }
    guide = candidate / "ACCEPTANCE_GUIDE.md"
    check(required_key(manifest, "acceptanceGuide", "build manifest") == expected, "acceptance guide build binding")
    check(local.sha256_file(guide) == expected["sha256"], "candidate acceptance guide hash")
    text = guide.read_text(encoding="utf-8")
    for marker in ("## 总检步骤", "三浏览器", f"LinkDigest {config['version']}", "## 价值指标记录表", "PRD §11.1", "不要包含 API Key"):
        check(marker in text, f"acceptance guide required section: {marker}")
    table_header = "| 指标 | PRD 目标（原文） | PRD 验证方法（原文） | 工程记录口径 | 记录（Syc 填写） |"
    check(table_header in text, "acceptance guide has exact PRD §11.1 metric table header")
    header_index = text.splitlines().index(table_header)
    metric_rows: list[tuple[str, str, str, str]] = []
    for line in text.splitlines()[header_index + 2:]:
        if not line.startswith("|"):
            break
        cells = [cell.strip() for cell in line.split("|")[1:-1]]
        check(len(cells) == 5, "acceptance guide metric row has exact five columns")
        metric_rows.append(tuple(cells[:4]))
    check(metric_rows == list(PRD_VALUE_METRICS), "acceptance guide PRD §11.1 metric table is exact")
    check("从“开始安装/配置”计时" not in text, "acceptance guide rejects pre-configuration first-value clock")
    records = source_manifest["source"]["records"]
    matches = [
        record for record in records
        if record["path"] == config["acceptanceGuideSource"] and record["type"] == "file"
    ]
    check(len(matches) == 1, "source manifest has one acceptance guide record")
    check(required_key(matches[0], "hash", "source manifest acceptance guide record") == expected["sha256"], "source acceptance guide hash")


def _git_fixture(root: Path, *args: str) -> None:
    result = subprocess.run(
        [r4a.GIT, *args],
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


def tracked_source_policy_cases(review: Path, config: dict[str, Any]) -> None:
    cases = review / "tracked-source-cases"
    cases.mkdir(mode=0o700)
    root = cases / "repo"
    root.mkdir()
    _git_fixture(root, "init", "-q")
    tracked = {
        "apps/desktop/tracked.txt": "index bytes\n",
        "scripts/native-host/tracked.py": "# tracked\n",
        "site/index.html": "excluded tracked top\n",
    }
    for relative, content in tracked.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    _git_fixture(root, "add", "--", *tracked)
    (root / ".git/info/exclude").write_text("*.ignored\n", encoding="utf-8")
    (root / "apps/desktop/tracked.txt").write_text("live tracked modification\n", encoding="utf-8")
    excluded_paths = (
        "apps/desktop/.cindy-write-test.txt",
        "apps/desktop/.dev-suite-analytics/event.json",
        "apps/desktop/.kb-cache/cache.bin",
        "apps/desktop/openwork-zh-translation/local.txt",
        "scripts/native-host/local_test_release.py.backup.2026-08-06T09-13-12Z",
        "scripts/native-host/release_unit.py.backup.2026-08-06T09-12-20Z",
        "apps/desktop/local.ignored",
    )
    for relative in excluded_paths:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("local only\n", encoding="utf-8")
    fixture_config = {
        **config,
        "sourceTopLevelAllowlist": ["apps", "scripts"],
        "excludedTopLevel": ["site"],
    }
    destination = cases / "snapshot"
    records = local.copy_live_snapshot(root, destination, fixture_config)
    check(
        (destination / "apps/desktop/tracked.txt").read_text(encoding="utf-8") == "live tracked modification\n",
        "local snapshot includes tracked live modification",
    )
    check({record["path"] for record in records} == {"apps/desktop/tracked.txt", "scripts/native-host/tracked.py"}, "local snapshot records exact tracked allowlist")
    check(not (destination / "site").exists(), "tracked excluded top-level omitted")
    for relative in excluded_paths:
        check(not (destination / relative).exists(), f"local-only path omitted: {relative}")

    unknown = dict(fixture_config)
    unknown["excludedTopLevel"] = []
    expect_local(lambda: local.validate_top_level(root, unknown), local.INVALID_UNSAFE, "unknown tracked top-level STOP")
    drift = dict(fixture_config)
    drift["sourceTopLevelAllowlist"] = ["apps", "missing", "scripts"]
    expect_local(lambda: local.validate_top_level(root, drift), local.INVALID_UNSAFE, "allowlist config drift STOP")


def policy_negative_cases(review: Path, config: dict[str, Any]) -> None:
    cases = review / "cases"
    cases.mkdir(mode=0o700)

    symlink = cases / "symlink"
    symlink.mkdir()
    (symlink / "real").write_text("x", encoding="utf-8")
    (symlink / "link").symlink_to("real")
    expect_local(lambda: local.portable_tree_records(symlink), local.INVALID_UNSAFE, "symlink rejected")

    hardlink = cases / "hardlink"
    hardlink.mkdir()
    (hardlink / "one").write_text("x", encoding="utf-8")
    os.link(hardlink / "one", hardlink / "two")
    expect_local(lambda: local.portable_tree_records(hardlink), local.INVALID_UNSAFE, "hardlink rejected")

    fifo = cases / "special"
    fifo.mkdir()
    os.mkfifo(fifo / "pipe")
    expect_local(lambda: local.portable_tree_records(fifo), local.INVALID_UNSAFE, "special entry rejected")

    secret_name = cases / "secret-name"
    secret_name.mkdir()
    (secret_name / "api-key.txt").write_text("placeholder", encoding="utf-8")
    expect_local(lambda: local.scan_secret_tree(secret_name, "negative"), local.INVALID_UNSAFE, "secret filename rejected")

    secret_content = cases / "secret-content"
    secret_content.mkdir()
    fake_marker = "-----BEGIN " + "PRIVATE KEY-----\nFAKE TEST ONLY\n"
    (secret_content / "fixture.txt").write_text(fake_marker, encoding="utf-8")
    expect_local(lambda: local.scan_secret_tree(secret_content, "negative"), local.INVALID_UNSAFE, "secret content rejected")

    frozen_hash_missing = cases / "frozen-hash-missing"
    (frozen_hash_missing / "config").mkdir(parents=True)
    missing_config = dict(config)
    missing_hashes = dict(config["r4aFrozenHashes"])
    missing_hashes.pop("scripts/native-host/release_unit.py")
    missing_config["r4aFrozenHashes"] = missing_hashes
    local.write_canonical(frozen_hash_missing / local.CONFIG_RELATIVE, missing_config)
    expect_local(
        lambda: local.load_config(frozen_hash_missing),
        local.INVALID_UNSAFE,
        "missing frozen r4a hash rejected",
    )

    frozen_hash_extra = cases / "frozen-hash-extra"
    (frozen_hash_extra / "config").mkdir(parents=True)
    extra_config = dict(config)
    extra_hashes = dict(config["r4aFrozenHashes"])
    extra_hashes["scripts/native-host/unpinned.py"] = "0" * 64
    extra_config["r4aFrozenHashes"] = extra_hashes
    local.write_canonical(frozen_hash_extra / local.CONFIG_RELATIVE, extra_config)
    expect_local(
        lambda: local.load_config(frozen_hash_extra),
        local.INVALID_UNSAFE,
        "extra frozen r4a hash rejected",
    )

    concurrent = cases / "concurrent"
    concurrent.mkdir()
    source = concurrent / "large.bin"
    source.write_bytes(b"a" * (2 * 1024 * 1024))
    destination = concurrent / "copied.bin"
    fired = False

    def mutate(_relative: Path, copied: int) -> None:
        nonlocal fired
        if not fired and copied >= 1024 * 1024:
            fired = True
            with source.open("ab") as handle:
                handle.write(b"b")

    fd = os.open(source, os.O_RDONLY | local.O_NOFOLLOW | local.O_CLOEXEC)
    try:
        records: list[dict[str, Any]] = []
        expect_local(
            lambda: local._walk_fd(fd, Path("large.bin"), {"excludedBasenames": [], "excludedSuffixes": []}, records, destination, copy_hook=mutate),
            local.CLEANUP_REQUIRED,
            "concurrent source mutation STOP",
        )
    finally:
        os.close(fd)


def static_safety_checks(root: Path) -> None:
    core = root / "scripts/native-host/local_test_release.py"
    check(ast.parse(core.read_text(encoding="utf-8")) is not None, "core Python parses")
    gate = root / "scripts/native-host/local_test_release_check.py"
    check(ast.parse(gate.read_text(encoding="utf-8")) is not None, "gate Python parses")
    extension = root / "scripts/extension_identity_artifact.py"
    check(ast.parse(extension.read_text(encoding="utf-8")) is not None, "extension artifact Python parses")
    text = core.read_text(encoding="utf-8")
    for forbidden in ("/usr/bin/open", "osascript", "launchctl"):
        check(forbidden not in text, f"static no forbidden action: {forbidden}")
    imports = {node.names[0].name for node in ast.walk(ast.parse(text)) if isinstance(node, ast.Import)}
    imports.update(node.module or "" for node in ast.walk(ast.parse(text)) if isinstance(node, ast.ImportFrom))
    check(not ({"socket", "urllib", "requests", "http", "http.client"} & imports), "no network library imported")
    check("subprocess.Popen" not in text, "no background executable launch")
    check("--deep\", \"--force" not in text and "--deep', '--force" not in text, "no deep signing")
    check("/Applications" not in text and "NativeMessagingHosts" not in text, "no installation target write")


def verify_real_dmg(audit: Path, candidate: Path, review: Path, source: Path, dependency: Path, config: dict[str, Any]) -> dict[str, Any]:
    package_patch = local.patch_package_manifest(source, dependency)
    unit_path = audit / "working/dmg-staging" / local.LOCAL_TEST_UNIT
    unit = local.load_json(unit_path, "audit local-test unit")
    check(local.canonical_bytes(unit) == unit_path.read_bytes(), "audit unit canonical")
    candidate_patch = unit["build"]["packageManifestPatch"]
    candidate_manifest = audit / "working/build-source-extracted" / config["sourceTreeName"] / "apps/desktop/Package.swift"
    check(local.sha256_file(candidate_manifest) == candidate_patch["afterHash"], "candidate Package.swift afterHash binding")
    check(package_patch["beforeHash"] == candidate_patch["beforeHash"], "review Package.swift beforeHash binding")
    check(package_patch["replacement"] == candidate_patch["replacement"], "review Package.swift single replacement binding")
    check(package_patch["afterHash"] != package_patch["beforeHash"], "review Package.swift local path patch applied")
    dmg = candidate / config["dmgName"]
    local.command_ok([local.HDITUTIL, "verify", str(dmg)])
    check(True, "hdiutil verify candidate")
    mount = review / "mount"
    mount.mkdir(mode=0o700)
    attach_argv = [
        local.HDITUTIL,
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
        str(dmg),
    ]
    attach = local.run_command(attach_argv)
    mounted = local.call_r4a(
        r4a.guarded_attach_operation,
        attach,
        dmg,
        mount,
        lambda dev: {"devHash": local.sha256_bytes(dev.encode("utf-8")), "verified": local.validate_staging(mount, source, unit)},
    )
    check(isinstance(mounted, dict), "readonly mounted staging verified")
    check(local.call_r4a(r4a.no_residual_mount, dmg, mount), "exact detach with no residual mount")
    verified = required_key(mounted, "verified", "mounted verification")
    app_result = required_key(verified, "appResult", "mounted verification")
    app_facts = required_key(app_result, "app", "mounted App result")
    host_facts = required_key(app_result, "host", "mounted App result")
    unit_app = required_key(unit, "app", "audit local-test unit")
    unit_host = required_key(unit, "host", "audit local-test unit")
    check(required_key(app_facts, "treeDigest", "mounted App facts") == required_key(unit_app, "treeDigest", "audit unit App facts"), "mounted App tree/unit binding")
    check(required_key(host_facts, "packageDigest", "mounted Host facts") == required_key(unit_host, "packageDigest", "audit unit Host facts"), "mounted Host package/unit binding")
    icon = required_key(app_facts, "icon", "mounted App facts")
    check(icon == required_key(unit_app, "icon", "audit unit App facts"), "mounted App icon/unit binding")
    check(icon["plistValue"] == "AppIcon", "mounted App icon plist value")
    check(
        icon["hash"] == local.sha256_file(source / "apps/desktop/Assets" / icon["file"]),
        "mounted App icon hash matches frozen source asset",
    )
    platform_icons = required_key(app_facts, "platformIcons", "mounted App facts")
    if "platformIcons" in unit_app:
        check(platform_icons == unit_app["platformIcons"], "mounted built-in platform icons/unit binding")
    else:
        # This existing candidate predates the manifest field. Do not mutate
        # its sealed unit: recompute the exact source/embedded facts instead.
        check(
            platform_icons == r4a.verify_platform_icons(mount / "LinkDigest.app", source),
            "legacy unit platform icons recompute from mounted App and source",
        )
    browser_support = required_key(app_facts, "browserSupport", "mounted App facts")
    check(
        browser_support["templateHashes"] == local.extension_artifact.verify_app_installer_resources(
            source,
            local.extension_artifact.load_identity(source),
            local.extension_artifact.validate_native_host_binding(source, local.extension_artifact.load_identity(source)),
        ),
        "mounted App browser-support templates match frozen extension templates",
    )
    return {"browserSupport": browser_support, "devEntryHash": mounted["devHash"], "icon": icon, "readonly": True, "residual": False}


def tamper_cases(audit: Path, review: Path, source: Path) -> None:
    original_app = audit / "working/dmg-staging/LinkDigest.app"
    tampered_app = review / "cases/tampered-app/LinkDigest.app"
    shutil.copytree(original_app, tampered_app, symlinks=True)
    executable = tampered_app / "Contents/MacOS/LinkDigestApp"
    with executable.open("ab") as handle:
        handle.write(b"tamper")
    result = local.run_command([local.CODESIGN, "--verify", "--strict", "--all-architectures", "--verbose=4", str(tampered_app)])
    check(result.returncode != 0, "App tamper breaks signature")

    original_package = original_app / "Contents/Resources/NativeHost" / local.HOST_PACKAGE_NAME
    tampered_package = review / "cases/tampered-package" / local.HOST_PACKAGE_NAME
    shutil.copytree(original_package, tampered_package, symlinks=True)
    host = tampered_package / "LinkDigestNativeHost"
    with host.open("ab") as handle:
        handle.write(b"tamper")
    try:
        stable_host.verify_package(tampered_package, source)
    except stable_host.StableHostError:
        check(True, "Host checksum tamper rejected")
    else:
        raise CheckFailure("Host checksum tamper accepted")


def focused_swift_tests(source: Path, review: Path) -> int:
    suites = (("ContractTests", 10), ("AppCompositionTests", 9), ("BrowserSupportInstallerTests", 30), ("BrowserSupportViewModelTests", 5), ("GRDBOrchestratorIntegrationTests", 12))
    total = 0
    for name, expected in suites:
        env, roots = local.isolated_environment(review, f"focused-{name}")
        args = [
            local.SWIFT,
            "test",
            "--package-path",
            str(source / "apps/desktop"),
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
            "--filter",
            name,
        ]
        result = local.run_command(args, cwd=source, env=env)
        combined = result.stdout + result.stderr
        check(result.returncode == 0, f"focused {name} process success")
        check(f"Executed {expected} tests, with 0 failures".encode() in combined, f"focused {name} {expected}/{expected} only")
        total += expected
    return total


def target_probe_check() -> dict[str, Any]:
    probe = local.target_probe()
    check(probe["unchanged"] is True, "real target probe unchanged")
    check(probe["status"] in {"BLOCKED", "PROBED"}, "real target probe strict status")
    targets = probe["targets"]
    check(isinstance(targets, list) and all(isinstance(item, dict) for item in targets), "real target probe target records")
    check(
        tuple(item.get("token") for item in targets) == r4a.TARGET_PROBE_TOKENS,
        "real target probe exact independent token contract",
    )
    return probe


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--existing-audit", required=True)
    parser.add_argument("--review-root", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    audit = Path(args.existing_audit)
    review = Path(args.review_root)
    print(f"AUDIT_ROOT={audit}")
    print(f"REVIEW_ROOT={review}")
    print("local-test-release-check: audit is read-only; all gate outputs go to review root")
    try:
        root = local.repository_root()
        config = local.load_config(root)
        extension_identity = local.extension_artifact.load_identity(root)
        local.extension_artifact_facts(root, config)
        local.verify_r4a_frozen(root, config)
        audit = local.validate_existing_audit_root(str(audit))
        review = validate_new_review_root(str(review))
        audit_before = r4a.inventory_tree(audit, include_metadata=True)
        review.mkdir(mode=0o700)
        candidate = audit / config["handoffDirectory"]
        report, build_manifest = canonical_checks(audit, candidate, config, extension_identity)
        source, dependency, source_manifest = source_archive_checks(candidate, review, config, build_manifest)
        extension = extension_artifact_checks(candidate, source, review, build_manifest, source_manifest, config)
        acceptance_guide_checks(candidate, source, build_manifest, source_manifest, config)
        static_safety_checks(root)
        tracked_source_policy_cases(review, config)
        policy_negative_cases(review, config)
        dmg_review = verify_real_dmg(audit, candidate, review, source, dependency, config)
        tamper_cases(audit, review, source)
        focused = focused_swift_tests(source, review)
        probe = target_probe_check()
        audit_after = r4a.inventory_tree(audit, include_metadata=True)
        check(audit_after == audit_before, "candidate audit byte/metadata read-only")

        result = {
            "assertions": TESTS + 1,
            "candidate": {
                "appTreeDigest": build_manifest["app"]["treeDigest"],
                "auditInventoryHash": audit_after,
                "candidateDigest": report["candidateDigest"],
                "dependencyArchiveHash": source_manifest["dependency"]["archiveHash"],
                "dmgHash": build_manifest["dmg"]["dmgHash"],
                "extensionArtifactHash": extension["artifact"]["sha256"],
                "extensionID": extension["extensionID"],
                "extensionVersion": extension["version"],
                "manifestTemplateHashes": {browser: value["sha256"] for browser, value in extension["manifestTemplates"].items()},
                "sourceArchiveHash": source_manifest["source"]["archiveHash"],
                "sourceManifestHash": local.sha256_file(candidate / "source" / local.SOURCE_MANIFEST),
                "toolFactsHash": build_manifest["toolFactsHash"],
            },
            "commands": [
                "hdiutil verify",
                "hdiutil attach readonly exact mount",
                "codesign verify strict all-architectures deep",
                "stable_host verify-package",
                "swift test --filter ContractTests",
                "swift test --filter AppCompositionTests",
                "swift test --filter BrowserSupportInstallerTests",
                "swift test --filter BrowserSupportViewModelTests",
                "swift test --filter GRDBOrchestratorIntegrationTests",
            ],
            "distributionClass": "local-test-ad-hoc",
            "dmgReview": dmg_review,
            "exitStatus": 0,
            "focusedSwiftTests": focused,
            "formatVersion": 1,
            "manualTestStatus": "READY_FOR_MANUAL_OPEN-candidate",
            "noGUIProfileNetworkInstall": True,
            "productStatus": "BLOCKED",
            "publicReleaseStatus": "BLOCKED",
            "reviewStatus": "LOCAL_GATE_PASS_AWAITING_INDEPENDENT_REVIEWER",
            "targetProbe": probe,
        }
        result_path = review / "gate-result.json"
        local.write_canonical(result_path, result)
        check(local.canonical_bytes(result) == result_path.read_bytes(), "canonical gate-result")
        print(f"local-test-release-check: PASS ({TESTS} assertions; focused Swift tests {focused}/66)")
        print(f"GATE_RESULT={result_path}")
        return 0
    except (CheckFailure, local.LocalTestError, r4a.ReleaseUnitError, local.extension_artifact.IdentityArtifactError) as error:
        code = error.code if isinstance(error, (local.LocalTestError, r4a.ReleaseUnitError)) else 1
        print(f"local-test-release-check: FAIL: {error}", file=sys.stderr)
        print(f"local-test-release-check: retained {audit} and {review}", file=sys.stderr)
        return code
    except BaseException as error:
        print(f"local-test-release-check: INTERNAL: {error}", file=sys.stderr)
        print(f"local-test-release-check: retained {audit} and {review}", file=sys.stderr)
        return local.INTERNAL_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
