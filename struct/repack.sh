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
# The job's stop grace period is the platform default (30s; jobs cannot
# change it); pg_repack bounds its abort cleanup to fit (see README.md).
set -eu

die() { printf 'repack.sh: %s\n' "$*" >&2; exit 2; }

# Install the stop handlers first: as PID 1, sh ignores SIGTERM unless it is
# trapped, so a stop during the preflight checks would otherwise be lost.
child=""
stop_requested=""
forward() {
  stop_requested=$1
  if [ -n "$child" ]; then
    printf 'repack.sh: received %s, forwarding to pg_repack (pid %s)\n' "$1" "$child" >&2
    kill -"$1" "$child" 2>/dev/null || true
  else
    printf 'repack.sh: received %s before pg_repack started; exiting\n' "$1" >&2
    exit 143
  fi
}
trap 'forward TERM' TERM
trap 'forward INT' INT

: "${REPACK_TABLE:?REPACK_TABLE is required}"
# Character whitelist first (rules out newlines, spaces, quotes), then the
# exact shape. grep is line-based, so the whitelist must come first.
case "$REPACK_TABLE" in
  *[!a-z0-9_.]*) die "refusing table: only [a-z0-9_.] characters are allowed" ;;
esac
printf '%s\n' "$REPACK_TABLE" | grep -Eqx 't[a-z0-9]+\.agent_execution_steps' \
  || die "refusing table '$REPACK_TABLE': only t<tenant>.agent_execution_steps is allowed"
: "${DATABASE_URL_DIRECT:?DATABASE_URL_DIRECT is required}"
db=${DATABASE_URL_DIRECT%%\?*}  # drop ?sslmode=... first (it may contain '/')
db=${db##*/}                     # then the path after the last '/' 
[ "$db" = "edgedive" ] || die "refusing database '$db': only edgedive is allowed"
# A query string can override the database (?dbname=...), so also ask the
# server which database this URL really reaches.
real_db=$(psql "$DATABASE_URL_DIRECT" -XAtc "SELECT current_database()") \
  || die "cannot connect with DATABASE_URL_DIRECT"
[ "$real_db" = "edgedive" ] || die "refusing: DATABASE_URL_DIRECT connects to '$real_db', not edgedive"

set -- --dbname="$DATABASE_URL_DIRECT" --no-superuser-check --no-order --no-kill-backend --wait-timeout=120 \
       --table="$REPACK_TABLE"

# Map an env var to a flag when set. Values are validated so a typo fails
# fast here instead of after connecting.
add() { # add ENV_NAME --flag REGEX
  eval "val=\${$1:-}"
  [ -z "$val" ] && return 0
  case "$val" in
    *[!0-9a-z.]*) die "$1 is not valid for $2: only [0-9a-z.] characters are allowed" ;;
  esac
  printf '%s\n' "$val" | grep -Eqx "$3" || die "$1='$val' is not valid for $2"
  set_args="$set_args $2=$val"
}
num='[0-9]+([.][0-9]+)?'
dur='[0-9]+([.][0-9]+)?(ms|s|m|min|h|d)?'
set_args=""
add REPACK_COPY_SLICE_PAGES    --copy-slice-pages    '[0-9]+'
add REPACK_DUTY_CYCLE          --duty-cycle          "$num"
add REPACK_MAX_SLICE_SLEEP     --max-slice-sleep     "$dur"
add REPACK_BACKOFF_IO_WAITERS  --backoff-io-waiters  '[0-9]+'
add REPACK_BACKOFF_WAL_GB      --backoff-wal-gb      "$num"
add REPACK_BACKOFF_REPLICA_LAG --backoff-replica-lag "$dur"
add REPACK_BACKOFF_STEP        --backoff-step        "$dur"
add REPACK_BACKOFF_MAX         --backoff-max         "$dur"
add REPACK_MAX_RUNTIME         --max-runtime         "$dur"
add REPACK_PROGRESS_INTERVAL   --progress-interval   "$dur"
add REPACK_APPLY_COUNT         --apply-count         '[0-9]+'
# shellcheck disable=SC2086  # values were whitelisted above: no whitespace or globs
set -- "$@" $set_args
case "${REPACK_DRY_RUN:-}" in
  1|true|yes) set -- "$@" --dry-run ;;
esac

size() {  # table name passed as a psql variable, never spliced into SQL
  echo "SELECT pg_size_pretty(pg_total_relation_size(:'tbl'))" \
    | psql "$DATABASE_URL_DIRECT" -XAt -v tbl="$REPACK_TABLE" 2>/dev/null || echo "?"
}

printf 'repack.sh: %s\n' "$(pg_repack --version)"
printf 'repack.sh: table=%s size_before=%s\n' "$REPACK_TABLE" "$(size)"
# Print the arguments without the connection URL (it holds the password).
shown=""
for a in "$@"; do
  case "$a" in --dbname=*) a="--dbname=<DATABASE_URL_DIRECT>" ;; esac
  shown="$shown $a"
done
printf 'repack.sh: pg_repack%s\n' "$shown"

# Run pg_repack as a child; the traps above forward stop signals to it.
[ -z "$stop_requested" ] || exit 143
pg_repack "$@" &
child=$!

# 'wait' returns early when a trapped signal arrives; keep waiting until the
# child has really exited so its cleanup can finish.
set +e
while :; do
  wait "$child"
  rc=$?
  kill -0 "$child" 2>/dev/null || break
done
set -e

printf 'repack.sh: pg_repack exited with status %s; size_after=%s\n' "$rc" "$(size)"
exit "$rc"
