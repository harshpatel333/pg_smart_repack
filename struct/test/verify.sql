-- Post-repack checks. Prints FAIL lines; exits non-zero on any failure.
\set ON_ERROR_STOP 1
SET search_path = t1test;
CREATE TEMP TABLE results(check_name text, ok bool, detail text);

INSERT INTO results
SELECT 'rows match shadow (id + md5(payload))', count(*) = 0, count(*) || ' mismatched ids'
FROM (SELECT id, md5(payload::text) h FROM agent_execution_steps) a
FULL JOIN shadow s USING (id)
WHERE a.h IS DISTINCT FROM s.h;

INSERT INTO results
SELECT 'row counts', (SELECT count(*) FROM agent_execution_steps) = (SELECT count(*) FROM shadow),
       (SELECT count(*) FROM agent_execution_steps) || ' vs shadow ' || (SELECT count(*) FROM shadow);

INSERT INTO results
SELECT 'indexes present and valid', count(*) = 3 AND bool_and(indisvalid AND indisready),
       string_agg(indexrelid::regclass::text || CASE WHEN indisvalid THEN '' ELSE '(INVALID)' END, ', ')
FROM pg_index WHERE indrelid = 'agent_execution_steps'::regclass;

INSERT INTO results
SELECT 'constraints present and validated', count(*) = 3 AND bool_and(convalidated),
       string_agg(conname || ':' || contype::text, ', ')
FROM pg_constraint WHERE conrelid = 'agent_execution_steps'::regclass AND contype IN ('p', 'u', 'f');

INSERT INTO results
SELECT 'fk holds', count(*) = 0, count(*) || ' orphan steps'
FROM agent_execution_steps s WHERE NOT EXISTS (SELECT 1 FROM executions e WHERE e.id = s.execution_id);

INSERT INTO results
SELECT 'no repack leftovers', count(*) = 0, coalesce(string_agg(relname, ', '), 'none')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'repack' AND c.relkind NOT IN ('v');

INSERT INTO results
SELECT 'no repack_trigger', count(*) = 0, count(*) || ' triggers'
FROM pg_trigger WHERE tgname = 'repack_trigger';

INSERT INTO results
SELECT 'no repack types left', count(*) = 0, coalesce(string_agg(typname, ', '), 'none')
FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'repack' AND typname LIKE 'pk_%';

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, check_name, detail FROM results;
SELECT count(*) FILTER (WHERE NOT ok) AS failures FROM results \gset
\if :failures
\echo VERIFY FAILED
SELECT 1/0;
\endif
\echo VERIFY OK
