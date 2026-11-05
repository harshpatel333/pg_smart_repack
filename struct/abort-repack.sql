-- Emergency abort for a pg_repack run whose client died without cleaning up
-- (SIGKILL, node loss, or a cleanup that failed). With the struct-throttle
-- build a normal job stop (SIGTERM) cleans up by itself; use this only when
-- the log does not end with "pg_repack aborted cleanly".
--
-- 1. Stop any pg_repack sessions still running on the server.
SELECT pid, state, now() - xact_start AS xact_age, left(query, 60) AS query,
       pg_terminate_backend(pid) AS terminated
FROM pg_stat_activity
WHERE application_name = 'pg_repack' AND pid <> pg_backend_pid();

-- 2. Drop every repack object (log tables, repack.table_<oid>, the
--    repack_trigger on the target table, pk types). The original table and
--    its data are not touched.
DROP EXTENSION IF EXISTS pg_repack CASCADE;

-- 3. Recreate the extension before the next run:
--    CREATE EXTENSION pg_repack;
