#!/bin/bash
# Trigger each back-off signal for real and check pause -> log line -> resume.
#   REPLICA_DATA=<replica data dir> PG_CTL=<pg_ctl> backoff-tests.sh
# Uses the harness table in $PGDATABASE (setup.sql) plus a streaming replica.
set -u
here=$(cd "$(dirname "$0")" && pwd)
PG_REPACK=${PG_REPACK:-$here/../../bin/pg_repack}
OUT=${OUT:-/tmp/repack-tests}; mkdir -p "$OUT"
fails=0
base=(--no-superuser-check --no-order --no-kill-backend --table=t1test.agent_execution_steps
      --progress-interval=2s --backoff-step=2s --copy-slice-pages=64 --duty-cycle=0.5)

wait_for() { # file regex timeout
  local i=0
  until grep -Eq "$2" "$1"; do sleep 0.5; i=$((i + 1)); [ $i -gt $(($3 * 2)) ] && return 1; done
  return 0
}
check() { # name log
  local name=$1 log=$2 ok=PASS
  grep -q "back-off: phase=" "$log" || ok=FAIL
  grep -q "back-off cleared after" "$log" || ok=FAIL
  [ "${3:-0}" -eq 0 ] || ok=FAIL
  psql -Xq -f "$here/verify.sql" > "$OUT/$name.verify" 2>&1 || ok=FAIL
  echo "=== $name: $ok (exit=${3:-?})"
  grep -E "back-off|WARNING" "$log" | head -6 | sed 's/^/    /'
  grep -E "VERIFY" "$OUT/$name.verify" | sed 's/^/    /'
  [ $ok = PASS ] || fails=$((fails + 1))
}

# 1. replica lag: delay replay on the standby, then remove the delay.
log=$OUT/backoff-replica.log
echo "recovery_min_apply_delay = '15s'" >> "$REPLICA_DATA/postgresql.auto.conf"
"$PG_CTL" -D "$REPLICA_DATA" reload >/dev/null
psql -XAtc "create table if not exists lagkick(x int); insert into lagkick values (1)" >/dev/null
"$PG_REPACK" "${base[@]}" --backoff-replica-lag=5s --backoff-max=6s > "$log" 2>&1 &
pid=$!
wait_for "$log" "signal=replica-lag" 120 || echo "    (no replica-lag back-off seen)"
sleep 12   # stay paused for a while: --backoff-max warnings should appear
sed -i "/recovery_min_apply_delay/d" "$REPLICA_DATA/postgresql.auto.conf"
"$PG_CTL" -D "$REPLICA_DATA" reload >/dev/null
wait $pid; rc=$?
check backoff-replica-lag "$log" $rc

# 2. WAL size: pg_wal sits at its recycled steady state, so set the threshold
#    below the current size (pauses at once), then shrink pg_wal to clear it.
log=$OUT/backoff-wal.log
cur=$(psql -XAtc "select greatest(0.1, round(sum(size) / 1024.0^3 - 0.5, 2)) from pg_ls_waldir()")
"$PG_REPACK" "${base[@]}" --backoff-replica-lag=0 --backoff-wal-gb="$cur" > "$log" 2>&1 &
pid=$!
wait_for "$log" "signal=wal-gb" 120 || echo "    (no wal-gb back-off seen; threshold $cur GB)"
sleep 6
psql -XAtc "alter system set max_wal_size = '256MB'" -c "select pg_reload_conf()" -c "checkpoint" -c "checkpoint" >/dev/null
wait $pid; rc=$?
psql -XAtc "alter system reset max_wal_size" -c "select pg_reload_conf()" >/dev/null
check backoff-wal-gb "$log" $rc

# 3. IO waiters: random point lookups that detoast cold values, from 32
#    clients, against a larger table ($IO_DB, loaded with setup.sql rows=N).
log=$OUT/backoff-io.log
cat > "$OUT/ioload.sql" <<'EOF'
\set k random(0, 99999)
SELECT length(payload->>'blob') FROM t1test.agent_execution_steps WHERE id = 's-' || (1 + 2 * :k);
EOF
"$PG_REPACK" "${base[@]}" --backoff-replica-lag=0 --backoff-wal-gb=0 --backoff-io-waiters=3 > "$log" 2>&1 &
pid=$!
wait_for "$log" "phase=copy pages=" 60
for i in 1 2 3; do
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  PGDATABASE=${IO_DB:-pacing} timeout 10 pgbench -n -f "$OUT/ioload.sql" -c 32 -j 4 -T 10 >/dev/null 2>&1
  grep -q "signal=io-waiters" "$log" && break
done
wait $pid; rc=$?
check backoff-io-waiters "$log" $rc

echo "BACKOFF: $fails failing case(s)"
exit $fails
