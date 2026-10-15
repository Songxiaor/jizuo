#!/usr/bin/env python3
"""跑测速：perfrun.py <输出目录> <app名:次数> [<app名:次数> ...]

每次启动前把资料库副本恢复成同一份，启动测速版（隔离数据、隔离抓取通道），
等它跑完场景自己退出，收集日志。多个 app 交替跑（A B A B…），抵消机器负载漂移。
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path("/private/tmp/jz-perf")
DATA = ROOT / "appsupport" / "LinkDigest"
PRISTINE = ROOT / "history.pristine.sqlite"
SOCKET = ROOT / "capture.sock"

TASKS = ",".join([
    "x_old=955e3aaa-0fbb-4d06-a263-1e6d1443e7fb",
    "weixin_old=fe19827f-649e-4229-9599-f7b7a00907e5",
    "douyin_old=8ba28d36-9997-4088-b3ae-d5cf9114d6ba",
    "github_old=46d3d219-444a-455a-a512-84486f32f8f5",
    "memo_old=50a46331-7f06-4ed9-93f0-510051d1fb6a",
    "note_long=2dbf7006-3a2a-4974-9265-17fb7a6192be",
    "x_long=811ee190-b9e3-4fdd-a71f-b0e1143053b3",
    "wiki=cf4876ea-efe3-4b19-946a-221ce21e43e4",
    "youtube=4751b51d-f332-4315-a2da-f228e4aaf4d9",
    "local_video=ece8507b-aab0-47a3-b814-9a1d0a02d51d",
])
READING = "wiki=cf4876ea-efe3-4b19-946a-221ce21e43e4"
TRANSCRIPT = "local_video=ece8507b-aab0-47a3-b814-9a1d0a02d51d"
PROFILE_READING = ",".join([
    "wiki=cf4876ea-efe3-4b19-946a-221ce21e43e4",
    "x_long=811ee190-b9e3-4fdd-a71f-b0e1143053b3",
    "youtube=4751b51d-f332-4315-a2da-f228e4aaf4d9",
    "note_long=2dbf7006-3a2a-4974-9265-17fb7a6192be",
    "weixin_old=fe19827f-649e-4229-9599-f7b7a00907e5",
    "github_old=46d3d219-444a-455a-a512-84486f32f8f5",
])


def restore_data():
    for suffix in ("", "-wal", "-shm"):
        p = DATA / f"history.sqlite{suffix}"
        if p.exists():
            p.unlink()
    subprocess.run(["cp", "-c", str(PRISTINE), str(DATA / "history.sqlite")], check=True)
    # 克隆出来的文件不在系统文件缓存里：先读一遍，模拟日常「关了再开」的热启动。
    with open(DATA / "history.sqlite", "rb") as f:
        while f.read(1 << 20):
            pass


def running_perf_pids():
    out = subprocess.run(["pgrep", "-f", "/private/tmp/jz-perf/.*app/Contents/MacOS/LinkDigest(App|Perf)"],
                         capture_output=True, text=True).stdout.split()
    return [int(x) for x in out]


def load_avg():
    return os.getloadavg()[0]


def run_once(app: Path, log: Path, scenario: str, timeout: float = 300):
    restore_data()
    if log.exists():
        log.unlink()
    env = {
        "LINKDIGEST_PERF_LOG": str(log),
        "LINKDIGEST_SMOKE_APPLICATION_SUPPORT_ROOT": str(ROOT / "appsupport"),
        "LINKDIGEST_SOCKET_PATH": str(SOCKET),
        "LINKDIGEST_PERF_SCENARIO": scenario,
        "LINKDIGEST_PERF_EXIT": "1",
        "LINKDIGEST_PERF_TASKS": os.environ.get("PERF_TASKS", TASKS),
        "LINKDIGEST_PERF_READING_TASK": READING,
        "LINKDIGEST_PERF_TRANSCRIPT_TASK": TRANSCRIPT,
        "LINKDIGEST_PERF_PROFILE_READING": PROFILE_READING,
        "LINKDIGEST_PERF_PROFILE_SECONDS": os.environ.get("PROFILE_SECONDS", "20"),
        "LINKDIGEST_PERF_SNAPSHOT_DIR": os.environ.get("SNAPSHOT_DIR", str(log.parent / (log.stem + "-shots"))),
    }
    cmd = ["open", "-g", "-n", "-W"]
    for k, v in env.items():
        cmd += ["--env", f"{k}={v}"]
    cmd.append(str(app))
    started = time.time()
    proc = subprocess.Popen(cmd)
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        for pid in running_perf_pids():
            subprocess.run(["kill", "-TERM", str(pid)])
        proc.wait(timeout=30)
        print(f"  TIMEOUT {app.name}", flush=True)
    return time.time() - started


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    scenario = os.environ.get("SCENARIO", "full")
    plan = []
    for spec in sys.argv[2:]:
        name, count = spec.split(":")
        plan.append((name, int(count)))
    rounds = max(c for _, c in plan)
    if running_perf_pids():
        print("a perf app is already running; abort")
        return 1
    for i in range(rounds):
        for name, count in plan:
            if i >= count:
                continue
            app = ROOT / f"{name}.app"
            log = out / f"{name}-{i + 1}.log"
            la = load_avg()
            elapsed = run_once(app, log, scenario)
            print(f"{name} run {i + 1}: {elapsed:.1f}s load={la:.1f}", flush=True)
            time.sleep(2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
