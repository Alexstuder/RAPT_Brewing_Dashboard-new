-- =============================================================================
-- baseline.sql — rapt Per-App Init-Baseline (Clean Cut)
-- =============================================================================
-- Purpose:  Reproduce the complete rapt schema end-state on a FRESH
--           rapt_dashboard Supabase DB in a single apply. No historical
--           create-then-drop cycles; this is the tested target state directly.
--
-- Covered:  Equivalent to rapt migrations 001–005, self-contained:
--           - 001_init_rapt_schema  → schema + tables + indexes
--           - 002_user_profiles     → user_profiles table + RLS
--           - 003_device_activity_view → device_activity_controllers view
--           - 004_rapt_user_vault   → RAPT vault RPCs
--             IMPORTANT: Email-lookup/seed dependency removed — baseline runs
--             cleanly on an empty auth.users (no hardcoded alex@alexstuder.ch).
--             The handle_new_user trigger creates user_profiles on demand.
--           - 005_rapt_telemetry_owner → proxy_sync RPCs (moved HERE from
--             assistent-DB), owner column on telemetry tables, brew_sessions,
--             device_activity_view finale.
--
-- proxy_sync role/grants:  NOW IN THIS DB (rapt-DB only). db-sync writes only
--   the rapt schema → proxy_sync lives exclusively in the rapt-DB.
--   The role itself is created by zz-set-role-passwords.sh (cicd territory).
--   This baseline handles DB-level grants only: CONNECT, SCHEMA USAGE,
--   and EXECUTE on the SECURITY DEFINER RPCs.
--   cicd-handoff: rapt zz-set-role-passwords.sh must CREATE ROLE proxy_sync
--   with dedicated RAPT_PROXY_SYNC_PASSWORD (already implemented, confirmed).
--
-- schema_migrations contract (Phase-2 runner):
--   Version format: 3-digit numeric string, IDENTICAL to aibrewgenius baseline
--   so the same generic runner can operate over both stacks.
--   '000' = this baseline (clean-cut starting point).
--   Future rapt-specific migrations start at '001' and insert their own version.
--   Runner logic: apply where version > MAX(applied); baseline is the floor.
--   INSERT ON CONFLICT DO NOTHING = idempotent.
--
-- EXCLUDED intentionally:
--   - email-lookup seed for alex@alexstuder.ch (per-app-DB pivot; user created
--     on-the-fly in Phase 5 SSO ticket flow, Entscheidung 6).
--   - Any reference to aibrewgenius schema or assistent-DB (no cross-DB FK).
--   - TimescaleDB restore hooks (Phase 4 concern, not baseline).
--   - Seed data.
--
-- Prerequisites (provided by supabase/postgres image + zz-set-role-passwords.sh):
--   - Extensions: pgcrypto, pgjwt, supabase_vault, uuid-ossp, timescaledb
--     NOTE: timescaledb is NOT auto-installed; this baseline installs it.
--   - Roles: anon, authenticated, service_role, supabase_admin, proxy_sync
--     (proxy_sync created by zz-set-role-passwords.sh with RAPT_PROXY_SYNC_PASSWORD)
--   - vault.secrets + vault.decrypted_secrets + vault.create_secret/update_secret
--   - auth.users (GoTrue core)
--
-- Apply:
--   cat RAPT_Brewing_Dashboard-new/db_scripts/baseline.sql \
--     | docker exec -i db-rapt psql -U supabase_admin -d postgres \
--         --variable=ON_ERROR_STOP=1
--
-- Idempotency:
--   Safe to apply twice on a fresh DB. create_hypertable uses if_not_exists=>TRUE.
--   The schema_migrations INSERT uses ON CONFLICT DO NOTHING.
-- =============================================================================

-- =============================================================================
-- PRE-FLIGHT: proxy_sync role must exist before the transaction begins.
-- zz-set-role-passwords.sh must have run first (cicd territory).
-- This guard prevents a cryptic mid-transaction error and rollback of the
-- entire baseline when the role is missing.
-- =============================================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'proxy_sync') THEN
    RAISE EXCEPTION 'proxy_sync-Rolle muss vor der Baseline existieren — erst zz-set-role-passwords.sh ausfuehren';
  END IF;
END $$;

-- TimescaleDB extension MUST be created outside the transaction
-- (CREATE EXTENSION can't run inside a transaction block in older PG versions)
SET search_path = public;
CREATE EXTENSION IF NOT EXISTS timescaledb;

BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

-- =============================================================================
-- SECTION 0: public.schema_migrations (Phase-2 runner anchor)
-- =============================================================================
-- Version format: '000', '001', '010' — identical to aibrewgenius baseline
-- so a single generic runner can operate over both stacks.
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version    text        PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.schema_migrations OWNER TO supabase_admin;
COMMENT ON TABLE public.schema_migrations IS
  'Phase-2 migrations runner tracking. '
  'Version format: 3-digit numeric string (000, 001, 010, ...). '
  'Identical format to aibrewgenius DB — same generic runner works on both stacks. '
  'Baseline inserts 000. Each subsequent migration inserts its own version '
  'at the end of its transaction. Runner: apply where version > MAX(applied).';

-- =============================================================================
-- SECTION 1: rapt Schema
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS rapt;
ALTER SCHEMA rapt OWNER TO supabase_admin;

-- anon intentionally excluded: app is fully behind AuthGate.
REVOKE ALL ON SCHEMA rapt FROM PUBLIC;
GRANT USAGE ON SCHEMA rapt TO authenticated, service_role;
-- proxy_sync needs USAGE to execute RPCs in this schema
GRANT USAGE ON SCHEMA rapt TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 1a. rapt.user_profiles
--     - rapt_api_key: always NULL since 004; kept for client compat
--     - rapt_configured: GENERATED (rapt_secret_id IS NOT NULL)
--     - No dependency on pre-existing auth.users rows — trigger handles
--       profile creation on any auth.users INSERT.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.user_profiles (
  id              uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name            text        NOT NULL,
  avatar_blob     text,
  rapt_user_id    text,
  rapt_api_key    text,           -- always NULL since 004; kept for client compat
  updated_at      timestamptz NOT NULL DEFAULT now(),
  rapt_secret_id  uuid            REFERENCES vault.secrets(id) ON DELETE SET NULL,
  rapt_configured boolean         GENERATED ALWAYS AS (rapt_secret_id IS NOT NULL) STORED
);
ALTER TABLE rapt.user_profiles OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_user_profiles_rapt_secret_id
  ON rapt.user_profiles (rapt_secret_id)
  WHERE rapt_secret_id IS NOT NULL;

-- Note: idx_rapt_user_profiles_id (id column) removed — the PRIMARY KEY on id
-- already provides an implicit B-tree index; a duplicate index is redundant.

GRANT SELECT, INSERT, UPDATE, DELETE ON rapt.user_profiles TO authenticated;
GRANT ALL ON rapt.user_profiles TO service_role;

ALTER TABLE rapt.user_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_user_owns_profile_select ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_select
  ON rapt.user_profiles FOR SELECT TO authenticated
  USING (id = auth.uid());

DROP POLICY IF EXISTS rapt_user_owns_profile_insert ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_insert
  ON rapt.user_profiles FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

DROP POLICY IF EXISTS rapt_user_owns_profile_update ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_update
  ON rapt.user_profiles FOR UPDATE TO authenticated
  USING  (id = auth.uid())
  WITH CHECK (id = auth.uid());

DROP POLICY IF EXISTS rapt_user_owns_profile_delete ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_delete
  ON rapt.user_profiles FOR DELETE TO authenticated
  USING (id = auth.uid());

-- ---------------------------------------------------------------------------
-- 1b. rapt.controllers — PK (owner, rapt_id)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.controllers (
  owner      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rapt_id    text        NOT NULL,
  name       text        NOT NULL,
  last_seen  timestamptz,
  raw        jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner, rapt_id)
);
ALTER TABLE rapt.controllers OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_controllers_owner ON rapt.controllers (owner);

ALTER TABLE rapt.controllers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_controllers_select ON rapt.controllers;
CREATE POLICY rapt_owner_controllers_select
  ON rapt.controllers FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.controllers TO authenticated;
GRANT ALL    ON rapt.controllers TO service_role;

-- ---------------------------------------------------------------------------
-- 1c. rapt.hydrometers — PK (owner, rapt_id)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.hydrometers (
  owner      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rapt_id    text        NOT NULL,
  name       text        NOT NULL,
  last_seen  timestamptz,
  raw        jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner, rapt_id)
);
ALTER TABLE rapt.hydrometers OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_hydrometers_owner ON rapt.hydrometers (owner);

ALTER TABLE rapt.hydrometers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_hydrometers_select ON rapt.hydrometers;
CREATE POLICY rapt_owner_hydrometers_select
  ON rapt.hydrometers FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.hydrometers TO authenticated;
GRANT ALL    ON rapt.hydrometers TO service_role;

-- ---------------------------------------------------------------------------
-- 1d. rapt.profiles — PK (owner, id)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.profiles (
  owner       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  id          text        NOT NULL,
  name        text        NOT NULL,
  deleted     boolean     DEFAULT false,
  is_public   boolean     DEFAULT false,
  created_on  timestamptz,
  modified_on timestamptz,
  raw         jsonb,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner, id)
);
ALTER TABLE rapt.profiles OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_profiles_owner ON rapt.profiles (owner);

ALTER TABLE rapt.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_profiles_select ON rapt.profiles;
CREATE POLICY rapt_owner_profiles_select
  ON rapt.profiles FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.profiles TO authenticated;
GRANT ALL    ON rapt.profiles TO service_role;

-- ---------------------------------------------------------------------------
-- 1e. rapt.telemetry_controllers — Hypertable; PK (owner, device_id, created_on)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.telemetry_controllers (
  owner                              uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id                          text        NOT NULL,
  created_on                         timestamptz NOT NULL,
  id                                 text,
  row_key                            text,
  mac_address                        text,
  rssi                               double precision,
  control_device_type                text,
  control_device_mac_address         text,
  control_device_temperature         double precision,
  temperature                        double precision,
  target_temperature                 double precision,
  min_target_temperature             double precision,
  max_target_temperature             double precision,
  total_run_time                     double precision,
  cooling_run_time                   double precision,
  cooling_starts                     double precision,
  heating_run_time                   double precision,
  heating_starts                     double precision,
  profile_id                         text,
  profile_step_id                    text,
  profile_session_start_date         timestamptz,
  profile_session_time               integer,
  profile_step_progress              integer,
  raw                                jsonb,
  PRIMARY KEY (owner, device_id, created_on)
);
ALTER TABLE rapt.telemetry_controllers OWNER TO supabase_admin;

SELECT public.create_hypertable(
  'rapt.telemetry_controllers'::regclass, 'created_on'::name,
  if_not_exists => true
);

CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_owner
  ON rapt.telemetry_controllers (owner);
CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_owner_time
  ON rapt.telemetry_controllers (owner, created_on DESC);
CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_profile
  ON rapt.telemetry_controllers (profile_id, created_on DESC)
  WHERE profile_id IS NOT NULL;

ALTER TABLE rapt.telemetry_controllers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_telemetry_controllers_select ON rapt.telemetry_controllers;
CREATE POLICY rapt_owner_telemetry_controllers_select
  ON rapt.telemetry_controllers FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.telemetry_controllers TO authenticated;
GRANT ALL    ON rapt.telemetry_controllers TO service_role;

-- ---------------------------------------------------------------------------
-- 1f. rapt.telemetry_hydrometers — Hypertable; PK (owner, hydrometer_id, created_on)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.telemetry_hydrometers (
  owner            uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  hydrometer_id    text        NOT NULL,
  created_on       timestamptz NOT NULL,
  id               text,
  row_key          text,
  mac_address      text,
  rssi             double precision,
  temperature      double precision,
  gravity          double precision,
  gravity_velocity double precision,
  battery          double precision,
  version          text,
  raw              jsonb,
  PRIMARY KEY (owner, hydrometer_id, created_on)
);
ALTER TABLE rapt.telemetry_hydrometers OWNER TO supabase_admin;

SELECT public.create_hypertable(
  'rapt.telemetry_hydrometers'::regclass, 'created_on'::name,
  if_not_exists => true
);

CREATE INDEX IF NOT EXISTS idx_telemetry_hydrometers_owner
  ON rapt.telemetry_hydrometers (owner);
CREATE INDEX IF NOT EXISTS idx_telemetry_hydrometers_owner_time
  ON rapt.telemetry_hydrometers (owner, created_on DESC);

ALTER TABLE rapt.telemetry_hydrometers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_telemetry_hydrometers_select ON rapt.telemetry_hydrometers;
CREATE POLICY rapt_owner_telemetry_hydrometers_select
  ON rapt.telemetry_hydrometers FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.telemetry_hydrometers TO authenticated;
GRANT ALL    ON rapt.telemetry_hydrometers TO service_role;

-- ---------------------------------------------------------------------------
-- 1g. rapt.brew_sessions — PK uuid; owner + RLS; client writes directly
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.brew_sessions (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  owner             uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  profile_id        text,
  name              text        NOT NULL,
  start_date        timestamptz NOT NULL,
  end_date          timestamptz NOT NULL,
  custom_start_date timestamptz,
  custom_end_date   timestamptz,
  temp_key          text,
  is_hydrometer_only boolean,
  is_manual         boolean     DEFAULT false,
  updated_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE rapt.brew_sessions OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_brew_sessions_owner
  ON rapt.brew_sessions (owner);
CREATE INDEX IF NOT EXISTS idx_brew_sessions_profile_start
  ON rapt.brew_sessions (profile_id, start_date);
CREATE INDEX IF NOT EXISTS idx_brew_sessions_start
  ON rapt.brew_sessions (start_date DESC);

ALTER TABLE rapt.brew_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_brew_sessions_select ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_select
  ON rapt.brew_sessions FOR SELECT TO authenticated
  USING (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_insert ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_insert
  ON rapt.brew_sessions FOR INSERT TO authenticated
  WITH CHECK (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_update ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_update
  ON rapt.brew_sessions FOR UPDATE TO authenticated
  USING  (owner = auth.uid())
  WITH CHECK (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_delete ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_delete
  ON rapt.brew_sessions FOR DELETE TO authenticated
  USING (owner = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON rapt.brew_sessions TO authenticated;
GRANT ALL ON rapt.brew_sessions TO service_role;

-- ---------------------------------------------------------------------------
-- 1h. Default privileges
-- ---------------------------------------------------------------------------
-- Run without FOR ROLE clause → executes as supabase_admin (current role),
-- matching table ownership. "FOR ROLE postgres" is a no-op.
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO authenticated, service_role;
-- Note: REVOKE … FROM anon omitted — anon has no USAGE on the rapt schema
-- (revoked above at section 1), so it can never reach tables; the REVOKE is a no-op.

-- ---------------------------------------------------------------------------
-- 1i. device_activity_controllers view (security_invoker = true so RLS
--     of base tables applies for the querying user)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS rapt.device_activity_controllers;
CREATE VIEW rapt.device_activity_controllers
  WITH (security_invoker = true)
AS
WITH ordered AS (
  SELECT
    owner, device_id, created_on, profile_id,
    LAG(created_on) OVER (
      PARTITION BY owner, device_id, profile_id ORDER BY created_on
    ) AS prev
  FROM rapt.telemetry_controllers
),
marked AS (
  SELECT
    owner, device_id, created_on, profile_id,
    SUM(
      CASE WHEN prev IS NULL OR created_on - prev > INTERVAL '7 days' THEN 1 ELSE 0 END
    ) OVER (
      PARTITION BY owner, device_id, profile_id ORDER BY created_on
    ) AS sess_n
  FROM ordered
)
SELECT
  m.owner,
  m.device_id,
  m.profile_id,
  p.name       AS profile_name,
  m.sess_n     AS session_index,
  MIN(m.created_on) AS first_seen,
  MAX(m.created_on) AS last_seen,
  COUNT(*)::int     AS point_count
FROM marked m
LEFT JOIN rapt.profiles p ON p.id = m.profile_id AND p.owner = m.owner
GROUP BY m.owner, m.device_id, m.profile_id, p.name, m.sess_n;

REVOKE SELECT ON rapt.device_activity_controllers FROM anon;
GRANT  SELECT ON rapt.device_activity_controllers TO authenticated;
GRANT  SELECT ON rapt.device_activity_controllers TO service_role;

-- =============================================================================
-- SECTION 2: SECURITY DEFINER RPCs
-- =============================================================================
-- All with SET search_path = '' and fully-qualified objects.
-- proxy_sync gets EXECUTE only on the sync RPCs — no direct table access.

-- ---------------------------------------------------------------------------
-- 2a. rapt.handle_new_user() — trigger on auth.users INSERT
--     Creates rapt.user_profiles row automatically for every new user.
--     No pre-existing user dependency (email-lookup seed removed per spec).
--     SECURITY DEFINER + SET search_path = '': privilege boundary.
--     REVOKE EXECUTE FROM PUBLIC: trigger-only, not callable directly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO rapt.user_profiles (id, name, updated_at)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'name', pg_catalog.split_part(NEW.email, '@', 1), 'Brewer'),
    now()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END $$;

ALTER FUNCTION rapt.handle_new_user() OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.handle_new_user() FROM PUBLIC;

DROP TRIGGER IF EXISTS on_rapt_user_created ON auth.users;
CREATE TRIGGER on_rapt_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION rapt.handle_new_user();

-- ---------------------------------------------------------------------------
-- 2b. rapt.get_my_rapt_creds()
--     SECURITY DEFINER to access vault.decrypted_secrets.
--     Tenant filter: filters on auth.uid() internally.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.get_my_rapt_creds()
RETURNS TABLE (username text, api_key text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_secret_id uuid;
  v_username  text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT up.rapt_user_id, up.rapt_secret_id
    INTO v_username, v_secret_id
  FROM rapt.user_profiles up
  WHERE up.id = v_uid;

  IF v_secret_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT v_username, ds.decrypted_secret::text
    FROM vault.decrypted_secrets ds
    WHERE ds.id = v_secret_id;
END $$;

ALTER FUNCTION rapt.get_my_rapt_creds() OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.get_my_rapt_creds() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rapt.get_my_rapt_creds() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2c. rapt.set_my_rapt_creds(text, text)
--     SECURITY DEFINER to write vault.secrets and update user_profiles.
--     Tenant filter: all writes scoped to auth.uid().
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.set_my_rapt_creds(
  p_rapt_user_id text,
  p_api_key      text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_secret_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Ensure profile exists (idempotent; trigger may have already created it)
  INSERT INTO rapt.user_profiles (id, name, updated_at)
  VALUES (v_uid, COALESCE(p_rapt_user_id, 'Brewer'), now())
  ON CONFLICT (id) DO NOTHING;

  SELECT up.rapt_secret_id INTO v_secret_id
  FROM rapt.user_profiles up
  WHERE up.id = v_uid;

  IF p_api_key IS NULL OR p_api_key = '' THEN
    IF v_secret_id IS NOT NULL THEN
      UPDATE rapt.user_profiles
        SET rapt_secret_id = NULL, rapt_user_id = NULL, updated_at = now()
      WHERE id = v_uid;
      DELETE FROM vault.secrets WHERE id = v_secret_id;
    ELSE
      UPDATE rapt.user_profiles
        SET rapt_user_id = NULL, updated_at = now()
      WHERE id = v_uid;
    END IF;
    RETURN;
  END IF;

  IF v_secret_id IS NULL THEN
    v_secret_id := vault.create_secret(
      new_secret      => p_api_key,
      new_name        => 'rapt_dash_' || v_uid::text,
      new_description => 'RAPT API key for user ' || v_uid::text
    );
    UPDATE rapt.user_profiles
      SET rapt_secret_id = v_secret_id, rapt_user_id = p_rapt_user_id,
          rapt_api_key = NULL, updated_at = now()
    WHERE id = v_uid;
  ELSE
    PERFORM vault.update_secret(secret_id => v_secret_id, new_secret => p_api_key);
    UPDATE rapt.user_profiles
      SET rapt_user_id = p_rapt_user_id, rapt_api_key = NULL, updated_at = now()
    WHERE id = v_uid;
  END IF;
END $$;

ALTER FUNCTION rapt.set_my_rapt_creds(text, text) OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.set_my_rapt_creds(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rapt.set_my_rapt_creds(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2d. rapt.get_all_rapt_creds_for_sync() — headless worker, no auth.uid()
--     EXECUTE: strictly only proxy_sync (RPC-only access, no direct tables).
--     SECURITY DEFINER: runs as supabase_admin to access vault.decrypted_secrets.
--     No auth.uid() check needed: proxy_sync connects directly (not via PostgREST).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.get_all_rapt_creds_for_sync()
RETURNS TABLE (owner uuid, rapt_user_id text, rapt_api_key text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
    SELECT up.id, up.rapt_user_id, ds.decrypted_secret::text
    FROM rapt.user_profiles up
    JOIN vault.decrypted_secrets ds ON ds.id = up.rapt_secret_id
    WHERE up.rapt_secret_id IS NOT NULL;
END $$;

ALTER FUNCTION rapt.get_all_rapt_creds_for_sync() OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 2e. rapt.upsert_controller_for — proxy_sync write RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_controller_for(
  p_owner uuid, p_rapt_id text, p_name text, p_last_seen timestamptz, p_raw jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO rapt.controllers (owner, rapt_id, name, last_seen, raw, updated_at)
  VALUES (p_owner, p_rapt_id, p_name, p_last_seen, p_raw, now())
  ON CONFLICT (owner, rapt_id) DO UPDATE
    SET name = EXCLUDED.name, last_seen = EXCLUDED.last_seen,
        raw = EXCLUDED.raw, updated_at = now();
END $$;

ALTER FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 2f. rapt.upsert_hydrometer_for — proxy_sync write RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_hydrometer_for(
  p_owner uuid, p_rapt_id text, p_name text, p_last_seen timestamptz, p_raw jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO rapt.hydrometers (owner, rapt_id, name, last_seen, raw, updated_at)
  VALUES (p_owner, p_rapt_id, p_name, p_last_seen, p_raw, now())
  ON CONFLICT (owner, rapt_id) DO UPDATE
    SET name = EXCLUDED.name, last_seen = EXCLUDED.last_seen,
        raw = EXCLUDED.raw, updated_at = now();
END $$;

ALTER FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 2g. rapt.upsert_profile_for — proxy_sync write RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_profile_for(
  p_owner uuid, p_id text, p_name text, p_deleted boolean, p_is_public boolean,
  p_created_on timestamptz, p_modified_on timestamptz, p_raw jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO rapt.profiles
    (owner, id, name, deleted, is_public, created_on, modified_on, raw, updated_at)
  VALUES
    (p_owner, p_id, p_name, p_deleted, p_is_public, p_created_on, p_modified_on, p_raw, now())
  ON CONFLICT (owner, id) DO UPDATE
    SET name = EXCLUDED.name, deleted = EXCLUDED.deleted, is_public = EXCLUDED.is_public,
        modified_on = EXCLUDED.modified_on, raw = EXCLUDED.raw, updated_at = now();
END $$;

ALTER FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 2h. rapt.insert_controller_telemetry_for — jsonb batch insert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.insert_controller_telemetry_for(
  p_owner uuid, p_device_id text, p_rows jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    INSERT INTO rapt.telemetry_controllers (
      owner, device_id, created_on, id, row_key, mac_address, rssi,
      control_device_type, control_device_mac_address, control_device_temperature,
      temperature, target_temperature, min_target_temperature, max_target_temperature,
      total_run_time, cooling_run_time, cooling_starts, heating_run_time, heating_starts,
      profile_id, profile_step_id, profile_session_start_date,
      profile_session_time, profile_step_progress, raw
    ) VALUES (
      p_owner, p_device_id, (r->>'createdOn')::timestamptz,
      r->>'id', r->>'rowKey', r->>'macAddress', (r->>'rssi')::double precision,
      r->>'controlDeviceType', r->>'controlDeviceMacAddress',
      (r->>'controlDeviceTemperature')::double precision,
      (r->>'temperature')::double precision, (r->>'targetTemperature')::double precision,
      (r->>'minTargetTemperature')::double precision, (r->>'maxTargetTemperature')::double precision,
      (r->>'totalRunTime')::double precision, (r->>'coolingRunTime')::double precision,
      (r->>'coolingStarts')::double precision, (r->>'heatingRunTime')::double precision,
      (r->>'heatingStarts')::double precision, r->>'profileId', r->>'profileStepId',
      (r->>'profileSessionStartDate')::timestamptz,
      (r->>'profileSessionTime')::int, (r->>'profileStepProgress')::int, r
    )
    ON CONFLICT (owner, device_id, created_on) DO NOTHING;
  END LOOP;
END $$;

ALTER FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 2i. rapt.insert_hydrometer_telemetry_for — jsonb batch insert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.insert_hydrometer_telemetry_for(
  p_owner uuid, p_hydrometer_id text, p_rows jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    INSERT INTO rapt.telemetry_hydrometers (
      owner, hydrometer_id, created_on, id, row_key, mac_address, rssi,
      temperature, gravity, gravity_velocity, battery, version, raw
    ) VALUES (
      p_owner, p_hydrometer_id, (r->>'createdOn')::timestamptz,
      r->>'id', r->>'rowKey', r->>'macAddress', (r->>'rssi')::double precision,
      (r->>'temperature')::double precision, (r->>'gravity')::double precision,
      (r->>'gravityVelocity')::double precision, (r->>'battery')::double precision,
      r->>'version', r
    )
    ON CONFLICT (owner, hydrometer_id, created_on) DO NOTHING;
  END LOOP;
END $$;

ALTER FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 2j. rapt.derive_brew_sessions_for — gap-detection for proxy_sync
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.derive_brew_sessions_for(p_owner uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE s record; m record;
BEGIN
  FOR s IN
    WITH ordered AS (
      SELECT created_on, profile_id,
             LAG(created_on) OVER (PARTITION BY profile_id ORDER BY created_on) AS prev
      FROM rapt.telemetry_controllers
      WHERE profile_id IS NOT NULL AND owner = p_owner
    ),
    marked AS (
      SELECT created_on, profile_id,
        SUM(CASE WHEN prev IS NULL OR created_on - prev > INTERVAL '7 days' THEN 1 ELSE 0 END)
          OVER (PARTITION BY profile_id ORDER BY created_on) AS sess_n
      FROM ordered
    )
    SELECT profile_id, sess_n AS session_index,
           MIN(created_on) AS first_seen, MAX(created_on) AS last_seen
    FROM marked GROUP BY profile_id, sess_n
  LOOP
    SELECT id INTO m
    FROM rapt.brew_sessions
    WHERE owner = p_owner AND profile_id = s.profile_id
      AND ABS(EXTRACT(EPOCH FROM (start_date - s.first_seen))) < 86400
    LIMIT 1;

    IF FOUND THEN
      UPDATE rapt.brew_sessions
        SET end_date = s.last_seen, updated_at = now()
      WHERE id = m.id AND owner = p_owner AND NOT is_manual AND end_date <> s.last_seen;
    ELSE
      INSERT INTO rapt.brew_sessions (owner, profile_id, name, start_date, end_date, is_manual)
      VALUES (
        p_owner, s.profile_id,
        COALESCE((SELECT name FROM rapt.profiles WHERE owner = p_owner AND id = s.profile_id),
                 '(unbenannter Sud)'),
        s.first_seen, s.last_seen, false
      );
    END IF;
  END LOOP;
END $$;

ALTER FUNCTION rapt.derive_brew_sessions_for(uuid) OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 2k. rapt.last_telemetry_ts_for — watermark query for proxy_sync
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.last_telemetry_ts_for(
  p_owner uuid, p_kind text, p_device text
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_ts timestamptz;
BEGIN
  IF p_kind = 'controller' THEN
    SELECT MAX(created_on) INTO v_ts
    FROM rapt.telemetry_controllers
    WHERE owner = p_owner AND device_id = p_device;
  ELSIF p_kind = 'hydrometer' THEN
    SELECT MAX(created_on) INTO v_ts
    FROM rapt.telemetry_hydrometers
    WHERE owner = p_owner AND hydrometer_id = p_device;
  ELSE
    RAISE EXCEPTION 'last_telemetry_ts_for: unbekannter p_kind %. Erlaubt: controller, hydrometer.', p_kind;
  END IF;
  RETURN v_ts;
END $$;

ALTER FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) OWNER TO supabase_admin;
REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) TO proxy_sync;

-- =============================================================================
-- SECTION 3: proxy_sync DB-level grants
-- =============================================================================
-- The role itself is created by zz-set-role-passwords.sh (cicd territory).
-- Here: DB-level CONNECT + SCHEMA USAGE.
-- NO direct table access for proxy_sync — all writes go through SECURITY
-- DEFINER RPCs above (which run as supabase_admin and bypass RLS safely).
-- =============================================================================

GRANT CONNECT ON DATABASE postgres TO proxy_sync;
-- SCHEMA USAGE already granted above (section 1 rapt schema grants)

COMMENT ON ROLE proxy_sync IS
  'Minimal-privilege role for the rapt-proxy db-sync worker. '
  'No BYPASSRLS, no access to auth.*/vault.* directly. '
  'Password set via zz-set-role-passwords.sh with dedicated RAPT_PROXY_SYNC_PASSWORD '
  '(NOT RAPT_POSTGRES_PASSWORD — separate secret per Lesson 2026-05-24). '
  'Schreibweg ausschliesslich via SECURITY DEFINER rapt.*_for()-RPCs. '
  'RAPT-Creds via rapt.get_all_rapt_creds_for_sync(). '
  'Baseline: RAPT_Brewing_Dashboard-new/db_scripts/baseline.sql.';

-- =============================================================================
-- SECTION 4: schema_migrations anchor (baseline = version '000')
-- =============================================================================
INSERT INTO public.schema_migrations (version, applied_at)
VALUES ('000', now())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- =============================================================================
-- Sanity checks (outside transaction, read-only)
-- =============================================================================
\echo ''
\echo '=== RAPT BASELINE SANITY CHECKS ==='

\echo ''
\echo '== TimescaleDB extension =='
SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';

\echo ''
\echo '== Hypertables =='
SELECT hypertable_schema, hypertable_name, num_dimensions
FROM timescaledb_information.hypertables
ORDER BY hypertable_name;

\echo ''
\echo '== Schema =='
SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'rapt';

\echo ''
\echo '== Tables =='
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'rapt' AND table_type = 'BASE TABLE'
ORDER BY table_name;

\echo ''
\echo '== RLS status =='
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'rapt'
ORDER BY tablename;

\echo ''
\echo '== Policy count =='
SELECT COUNT(*) AS policy_count FROM pg_policies WHERE schemaname = 'rapt';

\echo ''
\echo '== SECURITY DEFINER functions (search_path must be empty) =='
SELECT p.proname AS function, p.prosecdef, p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'rapt' AND p.prosecdef = true
ORDER BY p.proname;

\echo ''
\echo '== Trigger on auth.users =='
SELECT tgname FROM pg_trigger
WHERE tgrelid = 'auth.users'::regclass AND tgname = 'on_rapt_user_created';

\echo ''
\echo '== proxy_sync table grants on rapt.* (must be EMPTY — RPC-only) =='
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'proxy_sync' AND table_schema = 'rapt'
ORDER BY table_name, privilege_type;

\echo ''
\echo '== proxy_sync function grants on rapt.* =='
SELECT grantee, routine_schema, routine_name
FROM information_schema.role_routine_grants
WHERE grantee = 'proxy_sync' AND routine_schema = 'rapt'
ORDER BY routine_name;

\echo ''
\echo '== auth.users count (should be 0 on fresh DB — no seed user) =='
SELECT COUNT(*) AS auth_user_count FROM auth.users;

\echo ''
\echo '== schema_migrations =='
SELECT version, applied_at FROM public.schema_migrations ORDER BY version;

\echo ''
\echo '=== DONE ==='
