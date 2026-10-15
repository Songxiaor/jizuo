#!/usr/bin/env python3
"""汇总测速日志：perfreport.py <目录> [基准名 对照名]

每个 app、每一步取多次启动的中位数。给了两个名字就并排比，算变化百分比。
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

KEYS = {
    "launch": ["firstListReady", "firstDetailReady", "settled", "busyTotal", "longestStall", "bootstrapDone", "appInitEnd", "windowTask"],
    "scroll": ["droppedFrames", "frames", "busyP50", "busyP95", "busyMax", "over8ms", "over16ms", "over50ms", "busyTotal", "afterBusyTotal", "distance"],
    "step": ["ready", "settled", "busyTotal", "longestStall", "stallsOver50"],
}


def kind(step):
    if step == "launch":
        return "launch"
    if step.startswith("scroll."):
        return "scroll"
    return "step"


def load(directory: Path):
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))  # app -> step -> key -> values
    runs = defaultdict(int)
    for log in sorted(directory.glob("*.log")):
        app = log.stem.rsplit("-", 1)[0]
        runs[app] += 1
        for line in log.read_text(errors="replace").splitlines():
            parts = line.split("\t", 2)
            if len(parts) == 3 and parts[1] == "result":
                obj = json.loads(parts[2])
                step = obj.pop("step")
                for k, v in obj.items():
                    if isinstance(v, (int, float)) and not isinstance(v, bool):
                        data[app][step][k].append(float(v))
    return data, runs


def med(values):
    return statistics.median(values) if values else None


def fmt(v):
    if v is None:
        return "-"
    return f"{v:.0f}" if abs(v) >= 10 else f"{v:.1f}"


def main():
    directory = Path(sys.argv[1])
    data, runs = load(directory)
    apps = sys.argv[2:4] if len(sys.argv) >= 4 else sorted(data)
    print("runs:", {a: runs[a] for a in apps})
    steps = []
    for app in apps:
        for step in data[app]:
            if step not in steps:
                steps.append(step)
    for step in steps:
        keys = KEYS[kind(step)]
        print(f"\n## {step}")
        header = "key".ljust(16) + "".join(a[:14].rjust(15) for a in apps)
        if len(apps) == 2:
            header += "change".rjust(10)
        print(header)
        for key in keys:
            vals = [med(data[a][step].get(key, [])) for a in apps]
            if all(v is None for v in vals):
                continue
            row = key.ljust(16) + "".join(fmt(v).rjust(15) for v in vals)
            if len(apps) == 2 and vals[0] and vals[1] is not None:
                row += f"{(vals[1] - vals[0]) / vals[0] * 100:+.0f}%".rjust(10)
            print(row)


if __name__ == "__main__":
    main()
