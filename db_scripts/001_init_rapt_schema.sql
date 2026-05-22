-- ============================================================================
-- RAPT Brewing Dashboard — Postgres Schema
-- Backend-First Architecture: brew-proxy schreibt, App liest (mit Custom-Date-Writes).
-- TimescaleDB Hypertables für effiziente Time-Series Queries auf Jahre an Daten.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS rapt AUTHORIZATION supabase_admin;

-- ----------------------------------------------------------------------------
-- Stammdaten: Geräte und Profile (alle vom RAPT-API gepullt + lokal überschrieben)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rapt.controllers (
  rapt_id    text PRIMARY KEY,
  name       text NOT NULL,
  last_seen  timestamptz,
  raw        jsonb,                            -- Rohdaten zur Sicherheit / Debugging
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rapt.hydrometers (
  rapt_id    text PRIMARY KEY,
  name       text NOT NULL,
  last_seen  timestamptz,
  raw        jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rapt.profiles (
  id          text PRIMARY KEY,
  name        text NOT NULL,
  deleted     boolean DEFAULT false,
  is_public   boolean DEFAULT false,
  created_on  timestamptz,
  modified_on timestamptz,
  raw         jsonb,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- Telemetrie (Hypertables — TimescaleDB komprimiert + indexiert nach Zeit)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rapt.telemetry_controllers (
  device_id     text NOT NULL,
  created_on    timestamptz NOT NULL,
  id            text,
  row_key       text,
  mac_address   text,
  rssi          double precision,
  control_device_type text,
  control_device_mac_address text,
  control_device_temperature double precision,
  temperature   double precision,
  target_temperature double precision,
  min_target_temperature double precision,
  max_target_temperature double precision,
  total_run_time double precision,
  cooling_run_time double precision,
  cooling_starts double precision,
  heating_run_time double precision,
  heating_starts double precision,
  profile_id    text,
  profile_step_id text,
  profile_session_start_date timestamptz,
  profile_session_time int,
  profile_step_progress int,
  raw           jsonb,
  PRIMARY KEY (device_id, created_on)
);

CREATE TABLE IF NOT EXISTS rapt.telemetry_hydrometers (
  hydrometer_id    text NOT NULL,
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
  PRIMARY KEY (hydrometer_id, created_on)
);

-- TimescaleDB Extension aktivieren + Hypertables anlegen
CREATE EXTENSION IF NOT EXISTS timescaledb;
SELECT create_hypertable('rapt.telemetry_controllers', 'created_on', if_not_exists => true);
SELECT create_hypertable('rapt.telemetry_hydrometers', 'created_on', if_not_exists => true);

-- ----------------------------------------------------------------------------
-- Brew Sessions: ein "Bier" = profile_id + Zeitraum. Custom Dates können vom User
-- in der App überschrieben werden (UPDATE-Berechtigung für anon, da single-user).
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rapt.brew_sessions (
  profile_id         text PRIMARY KEY,        -- RAPT-Profile-UUID, oder 'manual.<uuid>' für manuelle Sessions
  name               text NOT NULL,
  start_date         timestamptz NOT NULL,    -- bei auto: aus Telemetrie abgeleitet; bei manual: user-input
  end_date           timestamptz NOT NULL,
  custom_start_date  timestamptz,             -- User-Override
  custom_end_date    timestamptz,             -- User-Override
  temp_key           text,
  is_hydrometer_only boolean,
  is_manual          boolean DEFAULT false,   -- true = vom User erstellt (Worker fasst sie nicht an)
  updated_at         timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- Indizes für typische Queries
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_profile
  ON rapt.telemetry_controllers (profile_id, created_on DESC)
  WHERE profile_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_brew_sessions_start
  ON rapt.brew_sessions (start_date DESC);

-- ----------------------------------------------------------------------------
-- Berechtigungen (Single-User Pattern: anon = volle Rechte)
-- Bei Multi-User später: anon zurück auf SELECT, RLS-Policies pro user
-- ----------------------------------------------------------------------------

GRANT USAGE ON SCHEMA rapt TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA rapt TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA rapt TO service_role;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA rapt TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO anon, authenticated, service_role;
