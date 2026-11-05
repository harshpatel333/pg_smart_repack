#!/bin/bash
# Correctness + abort matrix on the local harness (see README in this dir).
# Every case runs with the concurrent writer and must pass verify.sql.
here=$(cd "$(dirname "$0")" && pwd); cd "$here"
fails=0
t() { ./run-test.sh "$@" || fails=$((fails + 1)); }
P="--progress-interval=1s"

# --- correctness, every mode
t ok-defaults          ok -- $P
t ok-slice64-duty1     ok -- $P --copy-slice-pages=64 --duty-cycle=1
t ok-slice128-duty033  ok -- $P --copy-slice-pages=128 --duty-cycle=0.33 --apply-count=200
t ok-single-statement  ok -- $P --copy-slice-pages=0 --duty-cycle=0.5
t ok-no-backoff        ok -- $P --copy-slice-pages=256 --backoff-io-waiters=0 --backoff-wal-gb=0 --backoff-replica-lag=0
t ok-jobs2             ok -- $P --copy-slice-pages=256 --jobs=2
t ok-slice1            ok -- --progress-interval=5s --copy-slice-pages=1 --duty-cycle=1

# --- aborts: each must roll back, drop repack objects and exit non-zero
t abort-term-copy      abort --signal TERM --when "pages=[1-9][0-9]{2,}/" -- $P --copy-slice-pages=64 --duty-cycle=0.5
t abort-int-copy       abort --signal INT  --when "pages=[1-9][0-9]{2,}/" -- $P --copy-slice-pages=64 --duty-cycle=0.5
t abort-term-index     abort --signal TERM --when "phase=index"           -- $P --copy-slice-pages=512 --duty-cycle=1
t abort-term-apply     abort --signal TERM --when "phase=apply applied_rows=[1-9]" -- $P --copy-slice-pages=256 --duty-cycle=0.2 --apply-count=10 --switch-threshold=2
t abort-max-runtime    abort -- $P --copy-slice-pages=64 --duty-cycle=0.3 --max-runtime=12s
t any-term-swap        any   --signal TERM --when "phase=swap"            -- $P --copy-slice-pages=512 --duty-cycle=1

echo "MATRIX: $fails failing case(s)"
exit $fails
