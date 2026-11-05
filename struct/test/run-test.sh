#!/bin/bash
# Run one pg_repack scenario against the local harness with a concurrent writer.
#
#   run-test.sh NAME EXPECT [--signal SIG --when REGEX] [--] PG_REPACK_ARGS...
#
# EXPECT is "ok" (exit 0) or "abort" (non-zero exit with the clean-abort line).
# With --signal/--when, SIG is sent to pg_repack once its output matches REGEX.
# Afterwards verify.sql must pass in both cases: for an abort the original
# table must be untouched and nothing may be left in the repack schema.
#
# Env: PG_REPACK (client binary), WRITER_CLIENTS, WRITER_RATE, OUT (log dir),
# and the usual PGHOST/PGPORT/PGUSER/PGDATABASE.
set -u
here=$(cd "$(dirname "$0")" && pwd)
name=$1; expect=$2; shift 2
sig=""; when=""
while [ $# -gt 0 ]; do
  case $1 in
    --signal) sig=$2; shift 2 ;;
    --when) when=$2; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
PG_REPACK=${PG_REPACK:-$here/../../bin/pg_repack}
OUT=${OUT:-/tmp/repack-tests}; mkdir -p "$OUT"
log=$OUT/$name.log; wlog=$OUT/$name.writer.log
: > "$log"

stats() { psql -XAtc "select n_tup_ins, n_tup_upd, n_tup_del from pg_stat_user_tables where relid = 't1test.shadow'::regclass"; }
before=$(stats)

pgbench -n -D nrows=${ROWS:-20000} -f "$here/writer.pgbench" -c "${WRITER_CLIENTS:-4}" -R "${WRITER_RATE:-20}" -T 100000 > "$wlog" 2>&1 &
writer=$!
sleep 2

start=$(date +%s)
"$PG_REPACK" --no-superuser-check --no-order --no-kill-backend --wait-timeout=120 \
  --table=t1test.agent_execution_steps "$@" >> "$log" 2>&1 &
pid=$!

if [ -n "$sig" ]; then
  until grep -Eq "$when" "$log" || ! kill -0 $pid 2>/dev/null; do sleep 0.2; done
  if kill -0 $pid 2>/dev/null; then
    echo "[test] sending SIG$sig at: $(grep -E "$when" "$log" | head -1)" | tee -a "$log"
    kill -"$sig" $pid
  fi
fi
wait $pid; rc=$?
dur=$(( $(date +%s) - start ))

kill -TERM $writer 2>/dev/null; wait $writer 2>/dev/null
sleep 1
after=$(stats)
if grep -q "aborted\|ERROR" "$wlog"; then echo "[test] writer errors:"; grep -m3 "aborted\|ERROR" "$wlog"; fi

verify=$(psql -X -q -f "$here/verify.sql" 2>&1); vrc=$?
leftover_conns=$(psql -XAtc "select count(*) from pg_stat_activity where application_name = 'pg_repack'")

status=PASS
case $expect in
  ok)    [ $rc -eq 0 ] || status=FAIL ;;
  abort) { [ $rc -ne 0 ] && grep -q "^pg_repack aborted cleanly" "$log"; } || status=FAIL ;;
  any)   { [ $rc -eq 0 ] || grep -Eq "^pg_repack (aborted cleanly|interrupted after swap)" "$log"; } || status=FAIL ;;
esac
[ $vrc -eq 0 ] || status=FAIL
[ "$leftover_conns" = 0 ] || status=FAIL

echo "=== $name: $status (exit=$rc, ${dur}s, expect=$expect)"
echo "    writer ins/upd/del on shadow: before=$before after=$after"
grep -E "^pg_repack (aborted|interrupted|abort)|^INFO: aborting|back-off" "$log" | sed 's/^/    /' | head -8
echo "$verify" | grep -E "FAIL|VERIFY" | sed 's/^/    /'
[ "$leftover_conns" = 0 ] || echo "    leftover pg_repack sessions: $leftover_conns"
[ $status = PASS ]
