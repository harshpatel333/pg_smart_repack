-- Emergency abort for a pg_repack run whose client died without cleaning up
-- (SIGKILL, node loss, or a cleanup that failed). With the struct-throttle
-- build a normal job stop (SIGTERM) cleans up by itself; use this only when
-- the log does not end with "pg_repack aborted cleanly".
--
-- Run it connected to the repacked database (edgedive). Until it runs, the
-- leftover repack_trigger logs every write to the table into repack.log_<oid>,
-- so run it promptly.

-- 1. Stop pg_repack sessions still running in THIS database.
SELECT pid, state, now() - xact_start AS xact_age, left(query, 60) AS query,
       pg_terminate_backend(pid) AS terminated
FROM pg_stat_activity
WHERE application_name = 'pg_repack'
  AND datname = current_database()
  AND pid <> pg_backend_pid();

-- 2. Drop every repack object (log tables, repack.table_<oid>, the
--    repack_trigger on the target table, pk types). The original table and
--    its data are not touched. Dropping the trigger needs a brief ACCESS
--    EXCLUSIVE lock on the table; the lock_timeout keeps this from queueing
--    behind a long app transaction and blocking all traffic behind it.
--    If it fails with "canceling statement due to lock timeout", re-run it.
SET lock_timeout = '5s';
DROP EXTENSION IF EXISTS pg_repack CASCADE;
RESET lock_timeout;

-- 3. Recreate the extension before the next run:
--    CREATE EXTENSION pg_repack;
