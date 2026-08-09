#!/usr/bin/env python3
"""Focused check for scripts/build-debug-candidate.py universal build commands.

Only exercises build-command construction and canonical config wiring; never
invokes Swift, pnpm, or a real build.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "scripts/build-debug-candidate.py"
TESTS = 0
EXPECTED_ARCH_ARGUMENTS = ["--arch", "arm64", "--arch", "x86_64"]


class CheckFailure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    global TESTS
    if not condition:
        raise CheckFailure(message)
    TESTS += 1


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise CheckFailure(f"cannot load {path.name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    module = load_module("build_debug_candidate", TARGET)
    canonical = module.stable_host.load_config(ROOT)
    package_path = ROOT / "apps/desktop"

    build_command, show_command = module.build_swift_commands(canonical, package_path)

    check("--arch" in build_command, "build command must carry --arch flags")
    check(
        build_command.count("--arch") == 2,
        f"build command must carry two --arch flags, got {build_command.count('--arch')}",
    )
    arch_pairs = []
    index = 0
    while True:
        try:
            index = build_command.index("--arch", index)
        except ValueError:
            break
        arch_pairs.extend(build_command[index : index + 2])
        index += 2
    check(
        arch_pairs == EXPECTED_ARCH_ARGUMENTS,
        f"build command arch flags must be {EXPECTED_ARCH_ARGUMENTS}",
    )
    check(
        show_command == build_command + ["--show-bin-path"],
        "show-bin-path command must be exactly the build command plus --show-bin-path",
    )
    check(
        canonical["architectures"] == module.stable_host.SUPPORTED_ARCHITECTURES,
        "canonical native-host config architectures must equal SUPPORTED_ARCHITECTURES",
    )

    for abnormal in (
        {"architectures": ["arm64"]},
        {"architectures": ["x86_64", "arm64"]},
        {"architectures": []},
        {"architectures": ["arm64", "x86_64", "amd64"]},
    ):
        try:
            module.build_swift_commands(abnormal, package_path)
        except RuntimeError as error:
            check(
                "architectures must be exactly" in str(error),
                f"abnormal config must be rejected with a precise error: {error}",
            )
        else:
            raise CheckFailure(f"abnormal config must be rejected: {abnormal}")

    source = TARGET.read_text(encoding="utf-8")
    check(
        "config = stable_host.load_config(ROOT)" in source,
        "main must read native-host config through the canonical strict loader",
    )
    check(
        'json.loads((ROOT / "config/native-host.json")' not in source,
        "main must not read native-host.json with raw json.loads",
    )

    print(f"build-debug-candidate-check: PASS ({TESTS} assertions)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CheckFailure as error:
        print(f"build-debug-candidate-check: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
