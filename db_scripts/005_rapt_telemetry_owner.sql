-- =============================================================================
-- Migration 005: rapt Telemetry/Devices/Sessions → Multi-Tenant (owner + RLS + Schreib-RPCs)
-- =============================================================================
-- PROD-HINWEIS: Die UPDATE-Datenmigration in Schritt 2 (telemetry_controllers,
-- telemetry_hydrometers) hält auf großen Hypertables (30k+ Rows, viele Chunks)
-- für die gesamte Transaktion einen Access-Exclusive-Lock. Prod-Lauf MUSS in
-- einem Wartungsfenster / Off-Peak erfolgen. lock_timeout='5s' (gesetzt direkt
-- nach BEGIN) sorgt auf Prod für schnelles Fail-Fast statt Hänger. Lokal unkritisch.
-- =============================================================================
-- Was diese Migration tut:
--   1. owner-Spalte (uuid REFERENCES auth.users ON DELETE CASCADE) + Indizes auf
--      alle 6 Tabellen: controllers, hydrometers, profiles, telemetry_controllers,
--      telemetry_hydrometers, brew_sessions.
--   2. Datenmigration: Bestandsrows mit owner IS NULL → Alex (alex@alexstuder.ch).
--      GET DIAGNOSTICS row-count per Tabelle. No-op-sicher wenn kein Alex-User.
--   3. owner SET NOT NULL + PK-Wechsel (wenn keine NULL-owner-Rows mehr):
--      controllers/hydrometers: (owner, rapt_id)
--      profiles:                (owner, id)
--      telemetry_controllers:   (owner, device_id, created_on)
--      telemetry_hydrometers:   (owner, hydrometer_id, created_on)
--      brew_sessions:           PK bleibt uuid (kein PK-Wechsel, nur owner + RLS)
--      Idempotenz: PK-Wechsel wird übersprungen, wenn owner bereits im PK ist.
--   4. RLS aktivieren + getrennte Policies (USING/WITH CHECK, TO authenticated):
--      - controllers/hydrometers/profiles/telemetry_*: nur SELECT (read-only für Client)
--      - brew_sessions: alle vier Operationen (Client schreibt createManualSession/updateCustomDates)
--   5. SECURITY DEFINER Schreib-RPCs für db-sync-Worker (proxy_sync):
--      Variante (a) — RPC-gestempel-owner statt owner-bound RLS, weil proxy_sync
--      NOBYPASSRLS hat und keinen User-JWT → auth.uid() ist NULL im headless Kontext.
--      Alle RPCs: SET search_path='', voll-qualifiziert, KEIN auth.uid(), EXECUTE nur proxy_sync.
--      - upsert_controller_for
--      - upsert_hydrometer_for
--      - upsert_profile_for
--      - insert_controller_telemetry_for (jsonb-Batch)
--      - insert_hydrometer_telemetry_for (jsonb-Batch)
--      - derive_brew_sessions_for (Aggregation strikt WHERE owner=p_owner)
--      - last_telemetry_ts_for (Watermark-Abfrage, proxy braucht für inkrementelle Fetches)
--   6. Grants umstellen:
--      - anon: REVOKE auf allen 6 Tabellen + View + ALTER DEFAULT PRIVILEGES
--      - authenticated: SELECT auf allen 6 behalten (RLS mediiert);
--        INSERT/UPDATE/DELETE nur auf brew_sessions; REST entziehen
--      - proxy_sync: Tabellen-Grants auf allen 6 entziehen → nur noch EXECUTE auf RPCs
--   7. View device_activity_controllers neu mit security_invoker=true, owner in
--      PARTITION/JOIN/SELECT; Spalten-Shape für flutter-coder erhalten.
--
-- Sicherheit (Variante a, begründet im Epic-Spec):
--   proxy_sync hat NOBYPASSRLS und keinen User-JWT → auth.uid()=NULL. Eine owner-
--   bound RLS WITH CHECK würde JEDEN Worker-Insert ablehnen. Die SECURITY DEFINER
--   RPCs laufen als supabase_admin (Owner der Hypertables) → RLS ist für den
--   Schreibweg nicht im Weg. Konsistent mit Phase 1 (get_all_rapt_creds_for_sync).
--
-- Hypertable-RLS (TimescaleDB 2.16.1):
--   RLS wird auf der Parent-Tabelle aktiviert. TimescaleDB ≥ 2.x propagiert
--   Parent-Policies auf alle Chunks. Im Test mit zwei JWTs verifiziert dass
--   Chunk-Reads owner-gefiltert sind (User B sieht 0 Rows von Alex).
--
-- Idempotenz: 2× anwendbar ohne Fehler.
--   ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
--   CREATE OR REPLACE FUNCTION, DROP POLICY IF EXISTS vor CREATE POLICY,
--   DO $$-Guards für NOT NULL / PK-Wechsel (pg_constraint-Lookup),
--   Datenmigration WHERE owner IS NULL (verhindert Doppelstempelung).
--
-- DDL/Policies laufen als supabase_admin (nicht postgres — postgres ist nicht Owner).
-- =============================================================================

BEGIN;

-- Fail-fast bei Lock-Konflikt auf Prod (Hypertable-Chunks in Schritt 2).
-- Lokal irrelevant. Siehe PROD-HINWEIS im Header.
SET lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1. owner-Spalte auf alle 6 Tabellen
-- ---------------------------------------------------------------------------

ALTER TABLE rapt.controllers
  ADD COLUMN IF NOT EXISTS owner uuid REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE rapt.hydrometers
  ADD COLUMN IF NOT EXISTS owner uuid REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE rapt.profiles
  ADD COLUMN IF NOT EXISTS owner uuid REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE rapt.telemetry_controllers
  ADD COLUMN IF NOT EXISTS owner uuid REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE rapt.telemetry_hydrometers
  ADD COLUMN IF NOT EXISTS owner uuid REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE rapt.brew_sessions
  ADD COLUMN IF NOT EXISTS owner uuid REFERENCES auth.users(id) ON DELETE CASCADE;

-- ---------------------------------------------------------------------------
-- 1b. Indizes auf owner (RLS macht owner zum Per-Query-Prädikat → Pflicht)
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_controllers_owner
  ON rapt.controllers (owner);

CREATE INDEX IF NOT EXISTS idx_hydrometers_owner
  ON rapt.hydrometers (owner);

CREATE INDEX IF NOT EXISTS idx_profiles_owner
  ON rapt.profiles (owner);

-- Hypertables: einfacher owner-Index + kombinierter (owner, created_on DESC)
-- für typische Query: owner-Filter + Zeitfenster.
CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_owner
  ON rapt.telemetry_controllers (owner);

CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_owner_time
  ON rapt.telemetry_controllers (owner, created_on DESC);

CREATE INDEX IF NOT EXISTS idx_telemetry_hydrometers_owner
  ON rapt.telemetry_hydrometers (owner);

CREATE INDEX IF NOT EXISTS idx_telemetry_hydrometers_owner_time
  ON rapt.telemetry_hydrometers (owner, created_on DESC);

CREATE INDEX IF NOT EXISTS idx_brew_sessions_owner
  ON rapt.brew_sessions (owner);

-- ---------------------------------------------------------------------------
-- 2. Datenmigration: Bestandsrows → Alex' auth.uid()
--    Idempotent: WHERE owner IS NULL verhindert Doppelstempelung.
--    GET DIAGNOSTICS für expliziten Row-Count (kein IF FOUND nach Loop).
--    No-op-sicher: wenn kein Alex-User → Stempelung + NOT NULL/PK übersprungen.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_alex_id   uuid;
  v_row_count integer;
BEGIN
  SELECT id INTO v_alex_id
  FROM auth.users
  WHERE email = 'alex@alexstuder.ch';

  IF v_alex_id IS NULL THEN
    RAISE NOTICE 'alex@alexstuder.ch nicht in auth.users — owner-Stempelung übersprungen, NOT NULL/PK-Wechsel werden ausgelassen.';
    RETURN;
  END IF;

  RAISE NOTICE 'Alex uid = %, stempel Bestandsrows …', v_alex_id;

  UPDATE rapt.controllers SET owner = v_alex_id WHERE owner IS NULL;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RAISE NOTICE 'controllers: % Rows gestempelt.', v_row_count;

  UPDATE rapt.hydrometers SET owner = v_alex_id WHERE owner IS NULL;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RAISE NOTICE 'hydrometers: % Rows gestempelt.', v_row_count;

  UPDATE rapt.profiles SET owner = v_alex_id WHERE owner IS NULL;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RAISE NOTICE 'profiles: % Rows gestempelt.', v_row_count;

  UPDATE rapt.telemetry_controllers SET owner = v_alex_id WHERE owner IS NULL;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RAISE NOTICE 'telemetry_controllers: % Rows gestempelt.', v_row_count;

  UPDATE rapt.telemetry_hydrometers SET owner = v_alex_id WHERE owner IS NULL;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RAISE NOTICE 'telemetry_hydrometers: % Rows gestempelt.', v_row_count;

  UPDATE rapt.brew_sessions SET owner = v_alex_id WHERE owner IS NULL;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RAISE NOTICE 'brew_sessions: % Rows gestempelt.', v_row_count;

END $$;

-- ---------------------------------------------------------------------------
-- 3. owner SET NOT NULL + PK-Wechsel (nur wenn keine NULL-owner-Rows mehr)
--    Idempotenz: PK-Wechsel wird übersprungen, wenn owner bereits im PK ist.
--    Reihenfolge: Datenmigration zuerst (oben) → SET NOT NULL → PK-Wechsel.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_null_count bigint;
BEGIN
  -- Prüfe ob noch NULL-owner-Rows existieren (über alle 6 Tabellen)
  SELECT (
    (SELECT COUNT(*) FROM rapt.controllers         WHERE owner IS NULL) +
    (SELECT COUNT(*) FROM rapt.hydrometers         WHERE owner IS NULL) +
    (SELECT COUNT(*) FROM rapt.profiles            WHERE owner IS NULL) +
    (SELECT COUNT(*) FROM rapt.telemetry_controllers WHERE owner IS NULL) +
    (SELECT COUNT(*) FROM rapt.telemetry_hydrometers WHERE owner IS NULL) +
    (SELECT COUNT(*) FROM rapt.brew_sessions       WHERE owner IS NULL)
  ) INTO v_null_count;

  IF v_null_count > 0 THEN
    RAISE NOTICE 'Noch % NULL-owner-Rows vorhanden — SET NOT NULL und PK-Wechsel werden ausgelassen. Auf Prod nachziehen sobald Alex-User existiert.', v_null_count;
    RETURN;
  END IF;

  -- ---- SET NOT NULL ----

  ALTER TABLE rapt.controllers ALTER COLUMN owner SET NOT NULL;
  ALTER TABLE rapt.hydrometers ALTER COLUMN owner SET NOT NULL;
  ALTER TABLE rapt.profiles ALTER COLUMN owner SET NOT NULL;
  ALTER TABLE rapt.telemetry_controllers ALTER COLUMN owner SET NOT NULL;
  ALTER TABLE rapt.telemetry_hydrometers ALTER COLUMN owner SET NOT NULL;
  ALTER TABLE rapt.brew_sessions ALTER COLUMN owner SET NOT NULL;
  RAISE NOTICE 'owner SET NOT NULL auf allen 6 Tabellen gesetzt.';

  -- ---- PK-Wechsel controllers: (rapt_id) → (owner, rapt_id) ----
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.key_column_usage
    WHERE table_schema = 'rapt'
      AND table_name   = 'controllers'
      AND column_name  = 'owner'
      AND constraint_name = 'controllers_pkey'
  ) THEN
    ALTER TABLE rapt.controllers DROP CONSTRAINT controllers_pkey;
    ALTER TABLE rapt.controllers ADD PRIMARY KEY (owner, rapt_id);
    RAISE NOTICE 'controllers PK → (owner, rapt_id).';
  ELSE
    RAISE NOTICE 'controllers PK bereits (owner, rapt_id) — übersprungen.';
  END IF;

  -- ---- PK-Wechsel hydrometers: (rapt_id) → (owner, rapt_id) ----
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.key_column_usage
    WHERE table_schema = 'rapt'
      AND table_name   = 'hydrometers'
      AND column_name  = 'owner'
      AND constraint_name = 'hydrometers_pkey'
  ) THEN
    ALTER TABLE rapt.hydrometers DROP CONSTRAINT hydrometers_pkey;
    ALTER TABLE rapt.hydrometers ADD PRIMARY KEY (owner, rapt_id);
    RAISE NOTICE 'hydrometers PK → (owner, rapt_id).';
  ELSE
    RAISE NOTICE 'hydrometers PK bereits (owner, rapt_id) — übersprungen.';
  END IF;

  -- ---- PK-Wechsel profiles: (id) → (owner, id) ----
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.key_column_usage
    WHERE table_schema = 'rapt'
      AND table_name   = 'profiles'
      AND column_name  = 'owner'
      AND constraint_name = 'profiles_pkey'
  ) THEN
    ALTER TABLE rapt.profiles DROP CONSTRAINT profiles_pkey;
    ALTER TABLE rapt.profiles ADD PRIMARY KEY (owner, id);
    RAISE NOTICE 'profiles PK → (owner, id).';
  ELSE
    RAISE NOTICE 'profiles PK bereits (owner, id) — übersprungen.';
  END IF;

  -- ---- PK-Wechsel telemetry_controllers: (device_id, created_on) → (owner, device_id, created_on) ----
  -- TimescaleDB 2.16.1: DROP CONSTRAINT + ADD PRIMARY KEY auf Hypertable ist erlaubt.
  -- created_on bleibt im PK — Timescale-Anforderung (Partitionierungsspalte im PK).
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.key_column_usage
    WHERE table_schema = 'rapt'
      AND table_name   = 'telemetry_controllers'
      AND column_name  = 'owner'
      AND constraint_name = 'telemetry_controllers_pkey'
  ) THEN
    ALTER TABLE rapt.telemetry_controllers DROP CONSTRAINT telemetry_controllers_pkey;
    ALTER TABLE rapt.telemetry_controllers ADD PRIMARY KEY (owner, device_id, created_on);
    RAISE NOTICE 'telemetry_controllers PK → (owner, device_id, created_on).';
  ELSE
    RAISE NOTICE 'telemetry_controllers PK bereits mit owner — übersprungen.';
  END IF;

  -- ---- PK-Wechsel telemetry_hydrometers: (hydrometer_id, created_on) → (owner, hydrometer_id, created_on) ----
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.key_column_usage
    WHERE table_schema = 'rapt'
      AND table_name   = 'telemetry_hydrometers'
      AND column_name  = 'owner'
      AND constraint_name = 'telemetry_hydrometers_pkey'
  ) THEN
    ALTER TABLE rapt.telemetry_hydrometers DROP CONSTRAINT telemetry_hydrometers_pkey;
    ALTER TABLE rapt.telemetry_hydrometers ADD PRIMARY KEY (owner, hydrometer_id, created_on);
    RAISE NOTICE 'telemetry_hydrometers PK → (owner, hydrometer_id, created_on).';
  ELSE
    RAISE NOTICE 'telemetry_hydrometers PK bereits mit owner — übersprungen.';
  END IF;

  -- brew_sessions: PK bleibt uuid (global eindeutig, keine Cross-Tenant-Kollision).
  RAISE NOTICE 'brew_sessions PK bleibt uuid (kein Wechsel nötig).';

END $$;

-- ---------------------------------------------------------------------------
-- 4. RLS aktivieren auf allen 6 Tabellen
-- ---------------------------------------------------------------------------

ALTER TABLE rapt.controllers         ENABLE ROW LEVEL SECURITY;
ALTER TABLE rapt.hydrometers         ENABLE ROW LEVEL SECURITY;
ALTER TABLE rapt.profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE rapt.telemetry_controllers ENABLE ROW LEVEL SECURITY;
ALTER TABLE rapt.telemetry_hydrometers ENABLE ROW LEVEL SECURITY;
ALTER TABLE rapt.brew_sessions       ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 4a. Policies: controllers (read-only für authenticated; Schreib-RPCs via proxy_sync)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS rapt_owner_controllers_select ON rapt.controllers;
CREATE POLICY rapt_owner_controllers_select
  ON rapt.controllers
  FOR SELECT
  TO authenticated
  USING (owner = auth.uid());

-- ---------------------------------------------------------------------------
-- 4b. Policies: hydrometers (read-only für authenticated)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS rapt_owner_hydrometers_select ON rapt.hydrometers;
CREATE POLICY rapt_owner_hydrometers_select
  ON rapt.hydrometers
  FOR SELECT
  TO authenticated
  USING (owner = auth.uid());

-- ---------------------------------------------------------------------------
-- 4c. Policies: profiles (read-only für authenticated)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS rapt_owner_profiles_select ON rapt.profiles;
CREATE POLICY rapt_owner_profiles_select
  ON rapt.profiles
  FOR SELECT
  TO authenticated
  USING (owner = auth.uid());

-- ---------------------------------------------------------------------------
-- 4d. Policies: telemetry_controllers (read-only für authenticated)
--     RLS auf Parent-Table → TimescaleDB 2.16.1 propagiert auf Chunks.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS rapt_owner_telemetry_controllers_select ON rapt.telemetry_controllers;
CREATE POLICY rapt_owner_telemetry_controllers_select
  ON rapt.telemetry_controllers
  FOR SELECT
  TO authenticated
  USING (owner = auth.uid());

-- ---------------------------------------------------------------------------
-- 4e. Policies: telemetry_hydrometers (read-only für authenticated)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS rapt_owner_telemetry_hydrometers_select ON rapt.telemetry_hydrometers;
CREATE POLICY rapt_owner_telemetry_hydrometers_select
  ON rapt.telemetry_hydrometers
  FOR SELECT
  TO authenticated
  USING (owner = auth.uid());

-- ---------------------------------------------------------------------------
-- 4f. Policies: brew_sessions (alle 4 Operationen — Client schreibt)
--     createManualSession (INSERT), updateCustomDates (UPDATE) laufen aus Dart.
--     Client MUSS owner = auth.uid() mitschreiben — WITHOUT CHECK greift sonst.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS rapt_owner_brew_sessions_select ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_select
  ON rapt.brew_sessions
  FOR SELECT
  TO authenticated
  USING (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_insert ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_insert
  ON rapt.brew_sessions
  FOR INSERT
  TO authenticated
  WITH CHECK (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_update ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_update
  ON rapt.brew_sessions
  FOR UPDATE
  TO authenticated
  USING  (owner = auth.uid())
  WITH CHECK (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_delete ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_delete
  ON rapt.brew_sessions
  FOR DELETE
  TO authenticated
  USING (owner = auth.uid());

-- ---------------------------------------------------------------------------
-- 5a. RPC: rapt.upsert_controller_for(p_owner, p_rapt_id, p_name, p_last_seen, p_raw)
--     SECURITY DEFINER + SET search_path='' → läuft als supabase_admin, umgeht RLS.
--     KEIN auth.uid(): headless Worker hat keinen User-JWT.
--     p_owner kommt aus get_all_rapt_creds_for_sync() — vertrauenswürdige Quelle.
--     EXECUTE: strikt nur proxy_sync.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_controller_for(
  p_owner     uuid,
  p_rapt_id   text,
  p_name      text,
  p_last_seen timestamptz,
  p_raw       jsonb
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
    SET name       = EXCLUDED.name,
        last_seen  = EXCLUDED.last_seen,
        raw        = EXCLUDED.raw,
        updated_at = now();
END $$;

REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 5b. RPC: rapt.upsert_hydrometer_for(p_owner, p_rapt_id, p_name, p_last_seen, p_raw)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_hydrometer_for(
  p_owner     uuid,
  p_rapt_id   text,
  p_name      text,
  p_last_seen timestamptz,
  p_raw       jsonb
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
    SET name       = EXCLUDED.name,
        last_seen  = EXCLUDED.last_seen,
        raw        = EXCLUDED.raw,
        updated_at = now();
END $$;

REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 5c. RPC: rapt.upsert_profile_for(p_owner, p_id, p_name, p_deleted, p_is_public,
--                                   p_created_on, p_modified_on, p_raw)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_profile_for(
  p_owner       uuid,
  p_id          text,
  p_name        text,
  p_deleted     boolean,
  p_is_public   boolean,
  p_created_on  timestamptz,
  p_modified_on timestamptz,
  p_raw         jsonb
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
    SET name        = EXCLUDED.name,
        deleted     = EXCLUDED.deleted,
        is_public   = EXCLUDED.is_public,
        modified_on = EXCLUDED.modified_on,
        raw         = EXCLUDED.raw,
        updated_at  = now();
END $$;

REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 5d. RPC: rapt.insert_controller_telemetry_for(p_owner, p_device_id, p_rows jsonb)
--     jsonb-Batch-Insert: ein Roundtrip statt N. p_rows ist JSON-Array von Telemetrie-Rows.
--     Felder entsprechen db-sync.js insertControllerTelemetry (camelCase → snake_case).
--     ON CONFLICT (owner, device_id, created_on) DO NOTHING (inkrementell, kein UPDATE).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.insert_controller_telemetry_for(
  p_owner     uuid,
  p_device_id text,
  p_rows      jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r jsonb;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    INSERT INTO rapt.telemetry_controllers (
      owner, device_id, created_on,
      id, row_key, mac_address, rssi,
      control_device_type, control_device_mac_address, control_device_temperature,
      temperature, target_temperature, min_target_temperature, max_target_temperature,
      total_run_time, cooling_run_time, cooling_starts,
      heating_run_time, heating_starts,
      profile_id, profile_step_id, profile_session_start_date,
      profile_session_time, profile_step_progress,
      raw
    ) VALUES (
      p_owner,
      p_device_id,
      (r->>'createdOn')::timestamptz,
      r->>'id',
      r->>'rowKey',
      r->>'macAddress',
      (r->>'rssi')::double precision,
      r->>'controlDeviceType',
      r->>'controlDeviceMacAddress',
      (r->>'controlDeviceTemperature')::double precision,
      (r->>'temperature')::double precision,
      (r->>'targetTemperature')::double precision,
      (r->>'minTargetTemperature')::double precision,
      (r->>'maxTargetTemperature')::double precision,
      (r->>'totalRunTime')::double precision,
      (r->>'coolingRunTime')::double precision,
      (r->>'coolingStarts')::double precision,
      (r->>'heatingRunTime')::double precision,
      (r->>'heatingStarts')::double precision,
      r->>'profileId',
      r->>'profileStepId',
      (r->>'profileSessionStartDate')::timestamptz,
      (r->>'profileSessionTime')::int,
      (r->>'profileStepProgress')::int,
      r
    )
    ON CONFLICT (owner, device_id, created_on) DO NOTHING;
  END LOOP;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 5e. RPC: rapt.insert_hydrometer_telemetry_for(p_owner, p_hydrometer_id, p_rows jsonb)
--     Analog zu 5d. ON CONFLICT (owner, hydrometer_id, created_on) DO NOTHING.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.insert_hydrometer_telemetry_for(
  p_owner        uuid,
  p_hydrometer_id text,
  p_rows         jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r jsonb;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    INSERT INTO rapt.telemetry_hydrometers (
      owner, hydrometer_id, created_on,
      id, row_key, mac_address, rssi,
      temperature, gravity, gravity_velocity, battery, version,
      raw
    ) VALUES (
      p_owner,
      p_hydrometer_id,
      (r->>'createdOn')::timestamptz,
      r->>'id',
      r->>'rowKey',
      r->>'macAddress',
      (r->>'rssi')::double precision,
      (r->>'temperature')::double precision,
      (r->>'gravity')::double precision,
      (r->>'gravityVelocity')::double precision,
      (r->>'battery')::double precision,
      r->>'version',
      r
    )
    ON CONFLICT (owner, hydrometer_id, created_on) DO NOTHING;
  END LOOP;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 5f. RPC: rapt.derive_brew_sessions_for(p_owner uuid)
--     Serverseitige Gap-Detection: spiegelt deriveBrewSessions() in db-sync.js
--     ABER strikt auf WHERE owner = p_owner in JEDEM Sub-Query.
--     is_manual=true + custom_*-Rows bleiben unangetastet (wie heute).
--     Setzt new sessions mit owner = p_owner.
--     EXECUTE: strikt nur proxy_sync (wie alle *_for-RPCs).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.derive_brew_sessions_for(p_owner uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  s  record;
  m  record;
  rc integer;
BEGIN
  -- Gap-Detection: Telemetrie per profile_id, split bei Lücken >7 Tage.
  -- Strikt auf owner = p_owner in telemetry_controllers UND profiles JOIN.
  FOR s IN
    WITH ordered AS (
      SELECT created_on, profile_id,
             LAG(created_on) OVER (PARTITION BY profile_id ORDER BY created_on) AS prev
      FROM rapt.telemetry_controllers
      WHERE profile_id IS NOT NULL
        AND owner = p_owner
    ),
    marked AS (
      SELECT created_on, profile_id,
        SUM(CASE WHEN prev IS NULL OR created_on - prev > INTERVAL '7 days' THEN 1 ELSE 0 END)
          OVER (PARTITION BY profile_id ORDER BY created_on) AS sess_n
      FROM ordered
    )
    SELECT profile_id,
           sess_n           AS session_index,
           MIN(created_on)  AS first_seen,
           MAX(created_on)  AS last_seen
    FROM marked
    GROUP BY profile_id, sess_n
  LOOP
    -- Prüfe ob passende brew_session für (owner, profile_id, start_date ±1 Tag) existiert.
    -- ±24h-Fenster (86400 s) ist bewusst: toleriert Clock-Skew zwischen RAPT-API-
    -- Timestamps und lokalem Sync-Zeitpunkt; aus deriveBrewSessions() in db-sync.js übernommen.
    SELECT id INTO m
    FROM rapt.brew_sessions
    WHERE owner      = p_owner
      AND profile_id = s.profile_id
      AND ABS(EXTRACT(EPOCH FROM (start_date - s.first_seen))) < 86400
    LIMIT 1;

    IF FOUND THEN
      -- Update end_date, aber nur wenn nicht manuell und end_date sich geändert hat.
      UPDATE rapt.brew_sessions
      SET end_date   = s.last_seen,
          updated_at = now()
      WHERE id        = m.id
        AND owner     = p_owner
        AND NOT is_manual
        AND end_date <> s.last_seen;
      GET DIAGNOSTICS rc = ROW_COUNT;
      RAISE NOTICE 'derive_brew_sessions_for: Session % aktualisiert (% Rows geändert).', m.id, rc;
    ELSE
      -- Neue Session anlegen mit owner = p_owner.
      INSERT INTO rapt.brew_sessions
        (owner, profile_id, name, start_date, end_date, is_manual)
      VALUES (
        p_owner,
        s.profile_id,
        COALESCE(
          (SELECT name FROM rapt.profiles
           WHERE owner = p_owner AND id = s.profile_id),
          '(unbenannter Sud)'
        ),
        s.first_seen,
        s.last_seen,
        false
      );
    END IF;
  END LOOP;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 5g. RPC: rapt.last_telemetry_ts_for(p_owner uuid, p_kind text, p_device text)
--     Watermark-Abfrage: gibt MAX(created_on) für einen Device+Owner zurück.
--     Proxy braucht dies für inkrementelle Fetches (ersetzt direkten Table-SELECT
--     der nach Grant-Entzug in Schritt 6 nicht mehr möglich ist).
--     p_kind: 'controller' | 'hydrometer'
--     EXECUTE: strikt nur proxy_sync.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.last_telemetry_ts_for(
  p_owner  uuid,
  p_kind   text,
  p_device text
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ts timestamptz;
BEGIN
  IF p_kind = 'controller' THEN
    SELECT MAX(created_on) INTO v_ts
    FROM rapt.telemetry_controllers
    WHERE owner     = p_owner
      AND device_id = p_device;
  ELSIF p_kind = 'hydrometer' THEN
    SELECT MAX(created_on) INTO v_ts
    FROM rapt.telemetry_hydrometers
    WHERE owner         = p_owner
      AND hydrometer_id = p_device;
  ELSE
    RAISE EXCEPTION 'last_telemetry_ts_for: unbekannter p_kind %. Erlaubt: controller, hydrometer.', p_kind;
  END IF;
  RETURN v_ts;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 6. Grants umstellen
-- ---------------------------------------------------------------------------

-- 6a. anon: alle Tabellen-Grants schließen (waren in 001 offen)
REVOKE SELECT, INSERT, UPDATE, DELETE
  ON rapt.controllers,
     rapt.hydrometers,
     rapt.profiles,
     rapt.telemetry_controllers,
     rapt.telemetry_hydrometers,
     rapt.brew_sessions
  FROM anon;

-- ALTER DEFAULT PRIVILEGES: künftige Tabellen im rapt-Schema nicht automatisch für anon öffnen
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon;

-- 6b. authenticated: SELECT auf allen 6 behalten (RLS mediiert).
--     INSERT/UPDATE/DELETE nur auf brew_sessions (Client schreibt).
--     Auf anderen Tabellen INSERT/UPDATE/DELETE entziehen (Client liest nur).
REVOKE INSERT, UPDATE, DELETE
  ON rapt.controllers,
     rapt.hydrometers,
     rapt.profiles,
     rapt.telemetry_controllers,
     rapt.telemetry_hydrometers
  FROM authenticated;

-- brew_sessions: alle 4 Operationen für authenticated (RLS mediiert)
GRANT SELECT, INSERT, UPDATE, DELETE ON rapt.brew_sessions TO authenticated;

-- Sicherstellen SELECT auf allen 6 (RLS mediiert)
GRANT SELECT ON rapt.controllers, rapt.hydrometers, rapt.profiles,
               rapt.telemetry_controllers, rapt.telemetry_hydrometers
  TO authenticated;

-- 6c. proxy_sync: alle Tabellen-Grants auf den 6 Tabellen entziehen.
--     Schreibweg läuft ab jetzt ausschließlich über die *_for-RPCs (Schritt 5).
--     Lese-Watermark ebenfalls über RPC (last_telemetry_ts_for).
REVOKE SELECT, INSERT, UPDATE, DELETE
  ON rapt.controllers,
     rapt.hydrometers,
     rapt.profiles,
     rapt.telemetry_controllers,
     rapt.telemetry_hydrometers,
     rapt.brew_sessions
  FROM proxy_sync;

-- COMMENT ON ROLE fortschreiben
COMMENT ON ROLE proxy_sync IS
  'Minimal-privilegierte Rolle für den brew-proxy db-sync-Worker. '
  'Kein BYPASSRLS, kein Zugriff auf aibrewgenius.*/auth.*/vault.*. '
  'Passwort wird via zz-set-role-passwords.sh mit dedizierter PROXY_SYNC_PASSWORD-Variable gesetzt '
  '(NICHT ${POSTGRES_PASSWORD} — geteiltes Master-Passwort hebt least-privilege auf). '
  'Eingeführt in aibrewgenius/004_proxy_role.sql (Phase 1 Multi-VPS); Grants korrigiert in 005. '
  'Ab rapt/004_rapt_user_vault.sql: kein direkter SELECT auf rapt.user_profiles mehr; '
  'RAPT-Creds nur noch via SECURITY DEFINER rapt.get_all_rapt_creds_for_sync(). '
  'Ab rapt/005_rapt_telemetry_owner.sql: KEIN direkter Tabellenzugriff mehr auf rapt.*; '
  'Schreibweg ausschliesslich via SECURITY DEFINER rapt.*_for()-RPCs (upsert_controller_for, '
  'upsert_hydrometer_for, upsert_profile_for, insert_controller_telemetry_for, '
  'insert_hydrometer_telemetry_for, derive_brew_sessions_for) + '
  'Watermark via last_telemetry_ts_for(). '
  'Vault-Schuld aus aibrewgenius/004_proxy_role.sql + 005_fix_proxy_role_grants.sql getilgt '
  '(rapt.user_profiles in rapt/004_rapt_user_vault.sql verschlüsselt).';

-- ---------------------------------------------------------------------------
-- 7. View rapt.device_activity_controllers — owner-gefiltert neu definieren
--    security_invoker=true (PG15+): RLS der Basistabellen greift für den
--    abfragenden User → supabase_admin-Rechte des View-Owners umgehen RLS nicht.
--    owner in PARTITION BY / JOIN / SELECT, damit cross-tenant aggregation
--    auf gemeinsamen device_id-Werten ausgeschlossen ist.
--    Spalten-Shape: device_id, profile_id, profile_name, session_index,
--                   first_seen, last_seen, point_count (+ owner neu) — flutter-coder unberührt.
--    DROP + CREATE statt CREATE OR REPLACE: der neue SELECT fügt 'owner' als
--    erste Spalte ein → Postgres verbietet Spalten-Umbenennung via REPLACE.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS rapt.device_activity_controllers;
CREATE VIEW rapt.device_activity_controllers
  WITH (security_invoker = true)
AS
WITH ordered AS (
  SELECT
    owner,
    device_id,
    created_on,
    profile_id,
    LAG(created_on) OVER (
      PARTITION BY owner, device_id, profile_id
      ORDER BY created_on
    ) AS prev
  FROM rapt.telemetry_controllers
),
marked AS (
  SELECT
    owner,
    device_id,
    created_on,
    profile_id,
    SUM(
      CASE WHEN prev IS NULL OR created_on - prev > INTERVAL '7 days'
           THEN 1 ELSE 0 END
    ) OVER (
      PARTITION BY owner, device_id, profile_id
      ORDER BY created_on
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
LEFT JOIN rapt.profiles p
  ON p.id = m.profile_id
 AND p.owner = m.owner
GROUP BY m.owner, m.device_id, m.profile_id, p.name, m.sess_n;

-- View-Grants: anon entziehen, authenticated behalten (RLS via security_invoker)
REVOKE SELECT ON rapt.device_activity_controllers FROM anon;
GRANT  SELECT ON rapt.device_activity_controllers TO authenticated;
GRANT  SELECT ON rapt.device_activity_controllers TO service_role;

COMMIT;

-- =============================================================================
-- Sanity Checks (read-only, ausserhalb der Transaktion)
-- =============================================================================

\echo ''
\echo '== RLS-Status auf rapt-Tabellen =='
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'rapt'
ORDER BY tablename;

\echo ''
\echo '== Policies auf rapt.* (owner-gefiltert) =='
SELECT tablename, policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname = 'rapt'
ORDER BY tablename, cmd;

\echo ''
\echo '== PKs auf rapt.* (owner sollte Teil sein) =='
SELECT conname, conrelid::regclass, array_agg(a.attname ORDER BY array_position(pc.conkey, a.attnum)) AS pk_columns
FROM pg_constraint pc
JOIN pg_attribute a ON a.attrelid = pc.conrelid AND a.attnum = ANY(pc.conkey)
WHERE pc.contype = 'p'
  AND pc.conrelid IN (
    'rapt.controllers'::regclass,
    'rapt.hydrometers'::regclass,
    'rapt.profiles'::regclass,
    'rapt.telemetry_controllers'::regclass,
    'rapt.telemetry_hydrometers'::regclass
  )
GROUP BY conname, conrelid
ORDER BY conrelid::regclass::text;

\echo ''
\echo '== proxy_sync Tabellen-Grants auf rapt.* (soll LEER sein nach 005) =='
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'proxy_sync' AND table_schema = 'rapt'
ORDER BY table_name, privilege_type;

\echo ''
\echo '== proxy_sync Function-Grants auf rapt.* (soll *_for + get_all_rapt_creds enthalten) =='
SELECT grantee, routine_schema, routine_name, privilege_type
FROM information_schema.role_routine_grants
WHERE grantee = 'proxy_sync' AND routine_schema = 'rapt'
ORDER BY routine_name;

\echo ''
\echo '== anon Grants auf rapt.* (soll nur USAGE auf Schema + Sequences sein) =='
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'anon' AND table_schema = 'rapt'
ORDER BY table_name, privilege_type;

\echo ''
\echo '== Funktionen im rapt-Schema =='
SELECT proname, prosecdef, proconfig
FROM pg_proc
WHERE pronamespace = 'rapt'::regnamespace
ORDER BY proname;

\echo ''
\echo '== View device_activity_controllers — security_invoker =='
SELECT schemaname, viewname, definition
FROM pg_views
WHERE schemaname = 'rapt' AND viewname = 'device_activity_controllers';

SELECT reloptions
FROM pg_class
WHERE relname = 'device_activity_controllers'
  AND relnamespace = 'rapt'::regnamespace;
