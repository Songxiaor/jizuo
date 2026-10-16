#!/bin/bash
# 用法: profile.sh <app名> <场景> <采样秒数> <输出名>
set -u
APP=$1; SC=$2; SECS=$3; OUT=$4
T="$(cd "$(dirname "$0")" && pwd)"
D=/private/tmp/jz-perf/runs/profile-$OUT; mkdir -p $D
( cd /private/tmp/jz-perf && SCENARIO=$SC python3 $T/perfrun.py $D $APP:1 > $D/run.txt 2>&1 ) &
RUN=$!
LOG=$D/$APP-1.log
for i in $(seq 1 600); do grep -q "profile.begin" $LOG 2>/dev/null && break; sleep 0.1; done
P=$(pgrep -x LinkDigestPerf)
sleep 1.5
sample $P $SECS 1 -mayDie -file /private/tmp/jz-perf/samples/$OUT.txt >/dev/null 2>&1
wait $RUN
echo "sampled $OUT pid=$P"
