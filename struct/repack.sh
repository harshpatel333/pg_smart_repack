#!/bin/sh
# Entrypoint for the pg-repack Container Apps job (struct-throttle build).
#
# Required env:
#   REPACK_TABLE        schema-qualified table; only t*.agent_execution_steps
#   DATABASE_URL_DIRECT postgres:// URL of the server (direct, not pooled);
#                       its database must be edgedive
# Optional env:
#   REPACK_DRY_RUN=1    pass --dry-run (prints the size estimate, changes nothing)
#   Throttle knobs; unset or empty means "use the client default":
#   REPACK_COPY_SLICE_PAGES     --copy-slice-pages     (1024; 0 = one statement)
#   REPACK_DUTY_CYCLE           --duty-cycle           (0.33; 1 = no pacing)
#   REPACK_MAX_SLICE_SLEEP      --max-slice-sleep      (30s)
#   REPACK_BACKOFF_IO_WAITERS   --backoff-io-waiters   (16; 0 = off)
#   REPACK_BACKOFF_WAL_GB       --backoff-wal-gb       (35; 0 = off)
#   REPACK_BACKOFF_REPLICA_LAG  --backoff-replica-lag  (60s; 0 = off)
#   REPACK_BACKOFF_STEP         --backoff-step         (10s)
#   REPACK_BACKOFF_MAX          --backoff-max          (600s; warn-only)
#   REPACK_MAX_RUNTIME          --max-runtime          (4h; 0 = no limit)
#   REPACK_PROGRESS_INTERVAL    --progress-interval    (60s; 0 = off)
#   REPACK_APPLY_COUNT          --apply-count          (1000)
#
# Stopping the job sends SIGTERM to this script (PID 1). It is forwarded to
# pg_repack, which cancels its statements, rolls back, drops this table's
# repack objects and exits non-zero with "pg_repack aborted cleanly: ...".
# Keep the job's terminationGracePeriodSeconds long enough (600) for that.
set -eu

die() { echo "repack.sh: $*" >&2; exit 2; }

: "${REPACK_TABLE:?REPACK_TABLE is required}"
case "$REPACK_TABLE" in
  t[a-z0-9]*.agent_execution_steps) ;;
  *) die "refusing table '$REPACK_TABLE': only t*.agent_execution_steps is allowed" ;;
esac
# The schema part must be a plain tenant id (no quoting tricks, no dots).
echo "$REPACK_TABLE" | grep -Eq '^t[a-z0-9]+\.agent_execution_steps$' \
  || die "refusing table '$REPACK_TABLE': unexpected characters"
: "${DATABASE_URL_DIRECT:?DATABASE_URL_DIRECT is required}"
db=${DATABASE_URL_DIRECT##*/}   # path after the last '/'
db=${db%%\?*}                   # drop ?sslmode=... etc.
[ "$db" = "edgedive" ] || die "refusing database '$db': only edgedive is allowed"

set -- --dbname="$DATABASE_URL_DIRECT" --no-superuser-check --no-order --no-kill-backend --wait-timeout=120 \
       --table="$REPACK_TABLE"

# Map an env var to a flag when set. Values are validated so a typo fails
# fast here instead of after connecting.
add() { # add ENV_NAME --flag REGEX
  eval "val=\${$1:-}"
  [ -z "$val" ] && return 0
  echo "$val" | grep -Eq "$3" || die "$1='$val' is not valid for $2"
  set_args="$set_args $2=$val"
}
num='^[0-9]+([.][0-9]+)?$'
dur='^[0-9]+([.][0-9]+)?(ms|s|m|min|h|d)?$'
set_args=""
add REPACK_COPY_SLICE_PAGES    --copy-slice-pages    '^[0-9]+$'
add REPACK_DUTY_CYCLE          --duty-cycle          "$num"
add REPACK_MAX_SLICE_SLEEP     --max-slice-sleep     "$dur"
add REPACK_BACKOFF_IO_WAITERS  --backoff-io-waiters  '^[0-9]+$'
add REPACK_BACKOFF_WAL_GB      --backoff-wal-gb      "$num"
add REPACK_BACKOFF_REPLICA_LAG --backoff-replica-lag "$dur"
add REPACK_BACKOFF_STEP        --backoff-step        "$dur"
add REPACK_BACKOFF_MAX         --backoff-max         "$dur"
add REPACK_MAX_RUNTIME         --max-runtime         "$dur"
add REPACK_PROGRESS_INTERVAL   --progress-interval   "$dur"
add REPACK_APPLY_COUNT         --apply-count         '^[0-9]+$'
# shellcheck disable=SC2086  # values were validated above: no spaces or globs
set -- "$@" $set_args
case "${REPACK_DRY_RUN:-}" in
  1|true|yes) set -- "$@" --dry-run ;;
esac

size() {
  psql "$DATABASE_URL_DIRECT" -XAtc "SELECT pg_size_pretty(pg_total_relation_size('$REPACK_TABLE'))" 2>/dev/null || echo "?"
}

echo "repack.sh: $(pg_repack --version)"
echo "repack.sh: table=$REPACK_TABLE size_before=$(size)"
echo "repack.sh: pg_repack $* (--dbname shown redacted)" | sed 's|--dbname=[^ ]*|--dbname=<DATABASE_URL_DIRECT>|' 

# Run pg_repack as a child and forward stop signals to it. As PID 1, sh
# would otherwise swallow SIGTERM and the copy would keep running.
pg_repack "$@" &
child=$!
forward() {
  echo "repack.sh: received $1, forwarding to pg_repack (pid $child)" >&2
  kill -"$1" "$child" 2>/dev/null || true
}
trap 'forward TERM' TERM
trap 'forward INT' INT

# 'wait' returns early when a trapped signal arrives; keep waiting until the
# child has really exited so its cleanup can finish.
set +e
while :; do
  wait "$child"
  rc=$?
  kill -0 "$child" 2>/dev/null || break
done
set -e

echo "repack.sh: pg_repack exited with status $rc; size_after=$(size)"
exit "$rc"
