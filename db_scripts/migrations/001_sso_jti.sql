-- =============================================================================
-- 001_sso_jti.sql  — rapt migration
-- =============================================================================
-- Version:  001
-- Purpose:  Add persistent single-use SSO jti store (replay protection for
--           Phase-5 REST-SSO login-ticket redemption). The rapt-proxy consumes
--           each jti exactly once; persistence over proxy restarts is mandatory.
-- Schema:   rapt
-- Tables:   rapt.sso_used_tickets (new)
-- RPCs:     rapt.consume_sso_jti(text, timestamptz)  — single-use atomic insert
--           rapt.purge_expired_sso_jti()              — TTL cleanup (best-effort)
-- Author:   dba-coder  — applied as supabase_admin
-- Date:     2026-05-25
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
-- RLS / SECURITY DEFINER checklist:
--   [N/A] RLS intentionally omitted on rapt.sso_used_tickets.
--         Rationale: this table is NOT user-facing. No Flutter client, no
--         PostgREST client, and no authenticated user ever accesses it directly.
--         Access is exclusively through the SECURITY DEFINER RPCs executed by
--         proxy_sync on the server side. There are no grants to anon or
--         authenticated on the table, so the absence of RLS policies means no
--         row is visible through PostgREST even without RLS enabled.
--   [x]   SECURITY DEFINER functions have SET search_path = '' AND all objects
--         are fully qualified (rapt.sso_used_tickets, pg_catalog.now()).
--   [x]   proxy_sync gets EXECUTE on consume_sso_jti and purge_expired_sso_jti
--         only — no direct table access.
--   [x]   REVOKE EXECUTE FROM PUBLIC before selective GRANT TO proxy_sync.
-- =============================================================================

BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SELECT pg_catalog.set_config('search_path', '', false);
SET client_min_messages = warning;

-- ---------------------------------------------------------------------------
-- SECTION 1: rapt.sso_used_tickets
--
-- Stores every jti that has been redeemed. The PRIMARY KEY on jti enforces
-- uniqueness at the DB level, making the insert in consume_sso_jti() atomic
-- and TOCTOU-free (no check-then-act, just insert-and-count).
--
-- Columns:
--   jti     — the JWT ID claim from the SSO ticket (globally unique string)
--   exp     — exp claim of the ticket; indexed for efficient TTL cleanup
--   used_at — when the ticket was first redeemed (audit / debugging)
--
-- No RLS: see rationale in file header.
-- No table grants to anon / authenticated / public: proxy_sync writes only
-- through the SECURITY DEFINER RPCs below, never directly to the table.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.sso_used_tickets (
  jti      text        PRIMARY KEY,
  exp      timestamptz NOT NULL,
  used_at  timestamptz NOT NULL DEFAULT pg_catalog.now()
);
ALTER TABLE rapt.sso_used_tickets OWNER TO supabase_admin;

COMMENT ON TABLE rapt.sso_used_tickets IS
  'Persistent single-use jti store for SSO ticket replay protection (Phase 5). '
  'Written exclusively via consume_sso_jti() SECURITY DEFINER RPC by proxy_sync. '
  'No RLS intentionally: zero client-side exposure; all access is server-side only.';

-- Explicitly revoke all default privileges on this table.
-- The baseline applies DEFAULT PRIVILEGES that grant SELECT/INSERT/UPDATE/DELETE
-- to `authenticated` on every new table in the rapt schema. This table must not
-- be readable or writable by any client role — all access is via the SECURITY
-- DEFINER RPCs only.  Revoke from PUBLIC first (covers any implicit grants),
-- then explicitly from the client roles for belt-and-suspenders clarity.
REVOKE ALL ON rapt.sso_used_tickets FROM PUBLIC;
REVOKE ALL ON rapt.sso_used_tickets FROM anon;
REVOKE ALL ON rapt.sso_used_tickets FROM authenticated;
-- service_role retains its grants (needed for Supabase admin tooling / backups),
-- but direct client access is impossible because service_role requires the
-- service-role JWT which the Flutter client never holds.

-- Index on exp for efficient TTL cleanup in purge_expired_sso_jti().
CREATE INDEX IF NOT EXISTS sso_used_tickets_exp_idx
  ON rapt.sso_used_tickets (exp);

-- ---------------------------------------------------------------------------
-- SECTION 2: rapt.consume_sso_jti(p_jti text, p_exp timestamptz)
--
-- Atomically attempts to INSERT the jti. Uses ROW_COUNT to determine whether
-- the insert landed (fresh ticket) or conflicted (already redeemed = replay).
--
-- Returns:
--   true  — jti inserted for the first time; ticket is valid to proceed.
--   false — jti already existed; ticket is a replay, must be rejected.
--
-- SECURITY DEFINER: runs as supabase_admin, bypasses RLS (none on this table
-- anyway). search_path = '' prevents search-path hijacking. All objects fully
-- qualified. Caller (proxy_sync) does not need direct table access.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.consume_sso_jti(p_jti text, p_exp timestamptz)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inserted integer;
BEGIN
  INSERT INTO rapt.sso_used_tickets (jti, exp)
  VALUES (p_jti, p_exp)
  ON CONFLICT (jti) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;  -- explicit counter; no implicit FOUND pattern
  RETURN v_inserted = 1;
END;
$$;

ALTER FUNCTION rapt.consume_sso_jti(text, timestamptz) OWNER TO supabase_admin;

-- Least-privilege grants: only proxy_sync may call this RPC.
REVOKE EXECUTE ON FUNCTION rapt.consume_sso_jti(text, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.consume_sso_jti(text, timestamptz) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.consume_sso_jti(text, timestamptz) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.consume_sso_jti(text, timestamptz) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- SECTION 3: rapt.purge_expired_sso_jti()
--
-- Best-effort TTL cleanup. Deletes rows whose exp is older than 1 hour
-- (ticket TTL is ≤60 s, so 1 h is a generous safety margin). The proxy may
-- call this periodically (e.g. once per hour) without any correctness impact
-- if it never runs — a stale row only costs a few bytes and never causes false
-- replay rejections (jti is globally unique by construction).
--
-- Separate from consume_sso_jti to avoid lock contention during high-frequency
-- redemption bursts. Called best-effort; failures are safe to ignore.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.purge_expired_sso_jti()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer;
BEGIN
  DELETE FROM rapt.sso_used_tickets
  WHERE exp < pg_catalog.now() - interval '1 hour';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

ALTER FUNCTION rapt.purge_expired_sso_jti() OWNER TO supabase_admin;

-- Least-privilege grants: only proxy_sync may call this RPC.
REVOKE EXECUTE ON FUNCTION rapt.purge_expired_sso_jti() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.purge_expired_sso_jti() FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.purge_expired_sso_jti() FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.purge_expired_sso_jti() TO proxy_sync;

-- ---------------------------------------------------------------------------
-- schema_migrations version anchor — MUST be last, inside this transaction.
-- ---------------------------------------------------------------------------
INSERT INTO public.schema_migrations (version, applied_at)
VALUES ('001', pg_catalog.now())
ON CONFLICT (version) DO NOTHING;

COMMIT;
