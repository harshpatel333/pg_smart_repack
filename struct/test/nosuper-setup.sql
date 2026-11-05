-- Roles that mimic Azure: prod's "postgres" is NOT a superuser but inherits
-- pg_monitor + pg_read_all_stats + pg_signal_backend (via azure_pg_admin) and
-- owns the tenant tables. (To test the warn-and-disable fallback, revoke
-- pg_monitor and pg_read_all_stats from repack_admin for one run.)
\set ON_ERROR_STOP 1
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'repack_admin') THEN
    CREATE ROLE repack_admin LOGIN NOSUPERUSER;
  END IF;
END $$;
GRANT pg_monitor, pg_read_all_stats, pg_signal_backend TO repack_admin;
ALTER SCHEMA t1test OWNER TO repack_admin;
ALTER TABLE t1test.agent_execution_steps OWNER TO repack_admin;
ALTER TABLE t1test.executions OWNER TO repack_admin;
ALTER TABLE t1test.shadow OWNER TO repack_admin;
ALTER SEQUENCE t1test.step_seq OWNER TO repack_admin;
-- on Azure the non-superuser admin creates the extension and so owns it
ALTER SCHEMA repack OWNER TO repack_admin;
GRANT ALL ON ALL TABLES IN SCHEMA repack TO repack_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA repack TO repack_admin;
