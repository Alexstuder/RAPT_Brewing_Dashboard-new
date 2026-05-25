-- =============================================================================
-- NNN_<short_description>.sql  — rapt migration template
-- =============================================================================
-- Version:  NNN   (3-digit numeric string, e.g. 001, 010, 100)
-- Purpose:  <One sentence: what this migration changes and why>
-- Schema:   rapt  (Flutter dashboard uses .schema('rapt'); flag flutter-coder
--           on any column drop / rename / return-shape change)
-- Tables:   <list affected tables>
-- Author:   dba-coder  — applied as supabase_admin
-- Date:     YYYY-MM-DD
--
-- Rules (mandatory — do not remove this block):
--   - Forward-only.  NEVER edit this file once applied to any live DB.
--     Fix-forward with a NEW migration (next number up).
--   - Idempotent: CREATE TABLE IF NOT EXISTS, CREATE OR REPLACE FUNCTION,
--     ADD COLUMN IF NOT EXISTS, DROP POLICY IF EXISTS + CREATE POLICY,
--     CREATE INDEX IF NOT EXISTS.  create_hypertable uses if_not_exists=>TRUE.
--   - DDL runs as supabase_admin (the runner connects as supabase_admin).
--   - The schema_migrations INSERT is INSIDE the same transaction — a DDL
--     error rolls back the version row too, keeping the DB consistent.
--
-- IMPORTANT — Non-transactional statements (TimescaleDB):
--   CREATE EXTENSION and SELECT create_hypertable(...) cannot run inside a
--   transaction block (older PG/TimescaleDB versions will error or silently
--   corrupt state).  If this migration needs either of those:
--     1. Put them in the PRE-TRANSACTION block below (before BEGIN;).
--     2. Keep the rest of the DDL inside BEGIN; … COMMIT; as normal.
--   The runner applies the file with --single-transaction + ON_ERROR_STOP=1,
--   but the explicit BEGIN/COMMIT in the file provides an additional safety
--   net for runners that omit --single-transaction.
--
-- RLS / SECURITY DEFINER checklist (delete items that do not apply):
--   [ ] Every new user-facing table has ALTER TABLE … ENABLE ROW LEVEL SECURITY
--       AND at least one policy. (Enabled with no policy = nobody can read.)
--   [ ] Policies filter on auth.uid() (column: owner) — NEVER USING (true).
--   [ ] Write policies carry a WITH CHECK clause (separate from USING).
--   [ ] New indexes on every owner FK column RLS filters on.
--   [ ] SECURITY DEFINER functions have SET search_path = '' AND re-assert
--       owner filter internally (RLS is bypassed for them).
--   [ ] proxy_sync gets EXECUTE on sync RPCs only — no direct table access.
--   [ ] New API keys go into vault.secrets, not plaintext columns.
--       Add vault slot + generated *_configured flag + get/set RPCs.
--   [ ] GRANT least-privilege: authenticated gets SELECT (or SELECT/INSERT/
--       UPDATE/DELETE) where RLS guards rows; proxy_sync gets only EXECUTE
--       on its specific RPCs.
-- =============================================================================

-- =============================================================================
-- PRE-TRANSACTION block (non-transactional statements only)
-- Remove this section entirely if this migration needs no extensions or
-- hypertable conversions.
-- =============================================================================
-- Example: enable an extension not yet present
-- SET search_path = public;
-- CREATE EXTENSION IF NOT EXISTS some_extension;

-- Example: convert a table to a hypertable (must exist before BEGIN;)
-- SELECT public.create_hypertable(
--   'rapt.new_table'::regclass, 'created_on'::name,
--   if_not_exists => true
-- );
-- =============================================================================

BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SELECT pg_catalog.set_config('search_path', '', false);
SET client_min_messages = warning;

-- ---------------------------------------------------------------------------
-- Replace this block with the actual DDL for this migration.
-- ---------------------------------------------------------------------------

-- Example: add a column
-- ALTER TABLE rapt.some_table
--   ADD COLUMN IF NOT EXISTS new_col text;

-- Example: new table with RLS (owner column, not user_profile_id)
-- CREATE TABLE IF NOT EXISTS rapt.new_table (
--   id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
--   owner      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
--   name       text        NOT NULL,
--   updated_at timestamptz NOT NULL DEFAULT now()
-- );
-- ALTER TABLE rapt.new_table OWNER TO supabase_admin;
-- CREATE INDEX IF NOT EXISTS idx_rapt_new_table_owner
--   ON rapt.new_table (owner);
-- ALTER TABLE rapt.new_table ENABLE ROW LEVEL SECURITY;
-- DROP POLICY IF EXISTS rapt_owner_new_table_select ON rapt.new_table;
-- CREATE POLICY rapt_owner_new_table_select
--   ON rapt.new_table FOR SELECT TO authenticated
--   USING (owner = auth.uid());
-- GRANT SELECT ON rapt.new_table TO authenticated;
-- GRANT ALL    ON rapt.new_table TO service_role;

-- Example: SECURITY DEFINER proxy_sync write RPC
-- CREATE OR REPLACE FUNCTION rapt.upsert_something_for(p_owner uuid, …)
-- RETURNS void
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = ''
-- AS $$
-- BEGIN
--   INSERT INTO rapt.new_table (owner, …) VALUES (p_owner, …)
--   ON CONFLICT (…) DO UPDATE SET …;
-- END $$;
-- ALTER FUNCTION rapt.upsert_something_for(uuid, …) OWNER TO supabase_admin;
-- REVOKE EXECUTE ON FUNCTION rapt.upsert_something_for(uuid, …) FROM PUBLIC;
-- REVOKE EXECUTE ON FUNCTION rapt.upsert_something_for(uuid, …) FROM anon;
-- REVOKE EXECUTE ON FUNCTION rapt.upsert_something_for(uuid, …) FROM authenticated;
-- GRANT  EXECUTE ON FUNCTION rapt.upsert_something_for(uuid, …) TO proxy_sync;

-- Example: authenticated user SECURITY DEFINER RPC (vault access)
-- CREATE OR REPLACE FUNCTION rapt.my_rpc()
-- RETURNS text
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = ''
-- AS $$
-- DECLARE v_uid uuid := auth.uid();
-- BEGIN
--   IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
--   -- ... logic filtered on v_uid ...
-- END $$;
-- ALTER FUNCTION rapt.my_rpc() OWNER TO supabase_admin;
-- REVOKE EXECUTE ON FUNCTION rapt.my_rpc() FROM PUBLIC;
-- GRANT  EXECUTE ON FUNCTION rapt.my_rpc() TO authenticated;

-- ---------------------------------------------------------------------------
-- schema_migrations version anchor — MUST be last, inside this transaction.
-- Replace NNN with the actual 3-digit version string (same as the filename).
-- ON CONFLICT DO NOTHING makes re-apply a safe no-op.
-- ---------------------------------------------------------------------------
INSERT INTO public.schema_migrations (version, applied_at)
VALUES ('NNN', now())
ON CONFLICT (version) DO NOTHING;

COMMIT;
