# 测速工具

改性能前后用同一份资料、同一套动作量一遍，看改动到底快了多少。全部在 `/private/tmp/jz-perf` 里跑，
不碰正式版汲作和 `~/Library/Application Support/LinkDigest`（只读一次做快照）。

## 一次性准备

```bash
scripts/perf/prepare-data.sh
```

## 量一个版本

```bash
source scripts/xcode-env.sh
swift build -c release --package-path apps/desktop --scratch-path apps/desktop/.build-perf \
  --disable-sandbox --skip-update --product LinkDigestApp -Xswiftc -DLINKDIGEST_PERF
scripts/perf/make-perf-app.sh after          # 装成 /private/tmp/jz-perf/after.app
cd /private/tmp/jz-perf
SCENARIO=full python3 <仓库>/scripts/perf/perfrun.py runs/ab before:3 after:3   # 交替跑，抵消机器负载
python3 <仓库>/scripts/perf/perfreport.py runs/ab before after
```

- 测速版换了包名和可执行文件名（`LinkDigestPerf`），走隔离数据目录和单独的抓取通道，跑完自己退出。
- 每次启动前把资料库恢复成同一份快照，并先读一遍进文件缓存（模拟日常「关了再开」）。
- `SCENARIO`：`full`（启动、打开新旧内容、切侧栏、开设置、滑列表、滑长文）、`launch`、
  `visual`（截图巡检，配合 `imgdiff.swift` 逐像素比对改动前后界面）、`profile-detail` /
  `profile-screens` / `profile-reading` / `profile-list`（同一动作连做，配合 `profile.sh` 用
  `sample` 抓调用栈，`sampletree.py` 汇总）。
- 要打开的旧内容按本机资料挑的，换库时用 `PERF_TASKS=名字=任务ID,...` 覆盖。

## 记录的指标

- `ready`：内容画上屏幕；`settled`：主线程连续 0.5 秒没有 ≥2ms 的占用；`busyTotal`：这期间主线程
  一共忙了多久；`longestStall`：最长一次卡住。
- 滑动：每帧主线程占用的中位数 / 95 分位、超过 8.3ms（120Hz 一帧）和 16.7ms 的帧数、掉帧数。

日用构建里探针是空函数（`PerfProbe.swift` 的 `#else` 分支），场景脚本整个不编译。
