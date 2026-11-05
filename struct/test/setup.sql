-- Synthetic table shaped like tenant agent_execution_steps:
--   id varchar PK, UNIQUE (execution_id, sequence), FK to executions,
--   ~600 B of inline columns (prod has ~11 rows per heap page) and a
--   TOAST-heavy jsonb payload (lognormal around 8 kB, 0.1% of rows 0.5-30 MB).
-- A shadow table records md5(payload) per id; every writer statement keeps
-- it in sync atomically, so after the repack the two must match exactly.
-- Usage: psql -v rows=20000 -f setup.sql   (loads 2*rows, then deletes half)
\set ON_ERROR_STOP 1
DROP SCHEMA IF EXISTS t1test CASCADE;
CREATE SCHEMA t1test;
SET search_path = t1test;

CREATE TABLE rnd(b text NOT NULL);
-- 64 kB of random hex; pglz's 4 kB window cannot find repeats in it.
INSERT INTO rnd SELECT string_agg(md5(random()::text), '') FROM generate_series(1, 2048);

CREATE FUNCTION mkpayload(sz int, seed int) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('seed', seed, 'kind', 'snapshot',
           'blob', left(repeat(substr(b, 1 + (seed % 60000)) || b, (sz / 65536) + 2), greatest(sz, 16)))
  FROM t1test.rnd $$;

-- lognormal size around 8 kB, with 0.1% "big snapshots" of 0.5-30 MB
CREATE FUNCTION rndsize() RETURNS int LANGUAGE sql VOLATILE AS $$
  SELECT CASE WHEN random() < 0.001 THEN (524288 + random() * 30 * 1048576)::int
              ELSE least(4 * 1048576, (exp(ln(8000) + 1.3 * sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()))))::int END $$;

CREATE TABLE executions (id varchar PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now());
INSERT INTO executions SELECT 'e-' || g FROM generate_series(1, 2000) g;

CREATE SEQUENCE step_seq;
CREATE TABLE agent_execution_steps (
  id           varchar PRIMARY KEY,
  execution_id varchar NOT NULL REFERENCES executions(id),
  sequence     bigint NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  meta         text,
  payload      jsonb,
  UNIQUE (execution_id, sequence)
);
CREATE INDEX ON agent_execution_steps (created_at);

CREATE TABLE shadow (id varchar PRIMARY KEY, h text NOT NULL);

INSERT INTO agent_execution_steps (id, execution_id, sequence, created_at, meta, payload)
SELECT 's-' || g, 'e-' || (1 + g % 2000), nextval('step_seq'),
       now() - interval '1 second' * (2 * :rows - g), repeat(md5(g::text), 18),
       mkpayload(rndsize(), g)
FROM generate_series(1, 2 * :rows) g;
INSERT INTO shadow SELECT id, md5(payload::text) FROM agent_execution_steps;

-- Bloat it the way the archiver does: delete half (every other row), then
-- plain VACUUM so the space is free but still allocated.
DELETE FROM agent_execution_steps WHERE (substr(id, 3)::int % 2) = 0;
DELETE FROM shadow WHERE (substr(id, 3)::int % 2) = 0;
VACUUM ANALYZE agent_execution_steps, shadow;

SELECT pg_size_pretty(pg_total_relation_size('agent_execution_steps')) AS total,
       pg_size_pretty(pg_relation_size('agent_execution_steps')) AS heap,
       pg_size_pretty(pg_total_relation_size(reltoastrelid)) AS toast,
       (SELECT count(*) FROM agent_execution_steps) AS live_rows
FROM pg_class WHERE oid = 'agent_execution_steps'::regclass;
