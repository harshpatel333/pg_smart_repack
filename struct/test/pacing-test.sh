#!/bin/bash
# Pacing measurement: run the same repack at two duty cycles and compare disk
# write MB/s, utilisation and queue depth during the copy phase only.
#   DEV=nvme0n1 PGDATABASE=pacing pacing-test.sh 1.0 0.33
# Each run repacks the same table; after the first run it holds the same live
# data, so later runs copy the same bytes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
PG_REPACK=${PG_REPACK:-$here/../../bin/pg_repack}
OUT=${OUT:-/tmp/repack-tests}; mkdir -p "$OUT"
DEV=${DEV:-nvme0n1}

sampler() { # epoch wMB/s util% avg-queue  (from /proc/diskstats, 1s)
  python3 -I -c '
import sys, time
dev = sys.argv[1]
def read():
    for l in open("/proc/diskstats"):
        f = l.split()
        if f[2] == dev:
            return int(f[9]), int(f[12]), int(f[13])   # sectors written, io ms, weighted io ms
prev = read(); pt = time.time()
while True:
    time.sleep(1)
    cur = read(); t = time.time(); dt = t - pt
    print("%.0f %.1f %.1f %.2f" % (t, (cur[0]-prev[0])*512/1048576/dt,
          min(100, (cur[1]-prev[1])/10/dt), (cur[2]-prev[2])/1000/dt), flush=True)
    prev, pt = cur, t
' "$DEV"
}

for duty in "$@"; do
  log=$OUT/pacing-$duty.log; io=$OUT/pacing-$duty.io
  sampler > "$io" & sp=$!
  "$PG_REPACK" --no-superuser-check --no-order --no-kill-backend --table=t1test.agent_execution_steps \
     --duty-cycle="$duty" --progress-interval=10s --backoff-io-waiters=0 --backoff-wal-gb=0 \
     --backoff-replica-lag=0 2>&1 | while IFS= read -r l; do echo "$(date +%s) $l"; done > "$log"
  kill $sp
  t0=$(grep -m1 "copying .* heap pages" "$log" | cut -d' ' -f1)
  t1=$(grep -m1 "phase=index" "$log" | cut -d' ' -f1)
  awk -v a="$t0" -v b="$t1" -v d="$duty" '$1 >= a && $1 <= b { n++; w += $2; u += $3; q += $4; if ($2 > mw) mw = $2; if ($4 > mq) mq = $4 }
    END { printf "duty=%s copy_secs=%d avg_write_MBps=%.1f peak_write_MBps=%.1f avg_util=%.0f%% avg_queue=%.2f peak_queue=%.2f\n",
          d, b - a, w / n, mw, u / n, q / n, mq }' "$io"
done
