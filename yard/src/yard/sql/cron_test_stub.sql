-- Test mock for pg_cron extension.
-- Provides working cron.schedule/unschedule functions for testing.
-- The real pg_cron extension would be installed in production.

DROP SCHEMA IF EXISTS cron CASCADE;
CREATE SCHEMA cron;
CREATE TABLE cron.job (
  jobid bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jobname text,
  schedule text,
  command text,
  nodename text DEFAULT 'localhost',
  nodeport integer DEFAULT 5432,
  database text DEFAULT current_database(),
  username text DEFAULT current_user,
  active boolean DEFAULT true,
  jobclass text DEFAULT 'test'
);
CREATE FUNCTION cron.schedule(p_jobname text, p_schedule text, p_command text) RETURNS bigint AS $$
DECLARE v_jobid bigint;
BEGIN
  INSERT INTO cron.job (jobname, schedule, command)
  VALUES (p_jobname, p_schedule, p_command)
  RETURNING jobid INTO v_jobid;
  RETURN v_jobid;
END;
$$ LANGUAGE plpgsql;
CREATE FUNCTION cron.unschedule(p_jobid bigint) RETURNS boolean AS $$
BEGIN
  DELETE FROM cron.job WHERE jobid = p_jobid;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql;
CREATE FUNCTION cron.unschedule(p_jobname text) RETURNS boolean AS $$
BEGIN
  DELETE FROM cron.job WHERE jobname = p_jobname;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql;
