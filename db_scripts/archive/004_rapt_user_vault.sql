-- =============================================================================
-- Migration 004: rapt.user_profiles → auth.uid() + RLS + Vault + Service-RPC
-- =============================================================================
-- Was diese Migration tut (Übersicht):
--   1. rapt.user_profiles.id: text PK 'default' → uuid PK = auth.users.id
--      Datenmigration: 'default'-Row auf Alex' auth.uid() umschreiben (Lookup
--      via email='alex@alexstuder.ch'). FK REFERENCES auth.users(id) ON DELETE CASCADE.
--   2. Neue Spalten: rapt_secret_id (uuid FK vault.secrets), rapt_configured
--      (boolean GENERATED, kein Klartext). rapt_api_key wird genullt, bleibt
--      erhalten (kein DROP — Client/Migration-Reihenfolge sicher).
--   3. Bestehende Klartext-Keys → vault.secrets (create_secret), secret_id setzen,
--      Klartext nullen. Idempotent: nur wenn rapt_secret_id IS NULL.
--   4. RLS aktivieren + Policy 'id = auth.uid()' (USING + WITH CHECK getrennt).
--      anon-Grant auf user_profiles widerrufen.
--   5. SECURITY DEFINER RPCs im rapt-Schema:
--      - rapt.set_my_rapt_creds(p_rapt_user_id, p_api_key) — setzt beide Creds
--      - rapt.get_my_rapt_creds() — gibt (username, api_key) zurück
--      - rapt.get_all_rapt_creds_for_sync() — KEIN auth.uid()-Filter, NUR proxy_sync
--   6. proxy_sync-Grants: REVOKE SELECT auf user_profiles, GRANT EXECUTE auf Service-RPC.
--      Tilgt die in 004_proxy_role.sql / 005_fix_proxy_role_grants.sql dokumentierte
--      "Vault-Schuld für rapt.user_profiles".
--   7. rapt.handle_new_user()-Trigger: Auto-Insert in rapt.user_profiles bei neuem
--      auth.users (ON CONFLICT DO NOTHING).
--
-- Sicherheit:
--   - SECURITY DEFINER + SET search_path = '' (alle Objekte voll-qualifiziert)
--   - get/set_my_rapt_creds: interner auth.uid()-Filter, EXECUTE nur authenticated
--   - get_all_rapt_creds_for_sync: KEIN auth.uid()-Filter (bewusst — headless Worker
--     hat keinen User-JWT), EXECUTE strikt nur proxy_sync, PUBLIC/anon/authenticated revoked
--   - Klartext-Key nie mehr direkt lesbar: rapt_api_key=NULL, RLS schützt Row,
--     Decrypt-Weg ausschliesslich über die drei RPCs (als supabase_admin = Vault-Owner)
--
-- Idempotenz: 2× anwendbar ohne Fehler (IF NOT EXISTS, CREATE OR REPLACE,
--   DROP POLICY IF EXISTS, DO $$-Checks auf column_name / constraint_name).
-- DDL/Policies laufen als supabase_admin (nicht postgres).
-- Scope: NUR rapt.user_profiles + RPCs. Telemetrie/Device-Tabellen nicht angetastet (Phase 2).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1a. Neue Spalten auf rapt.user_profiles
-- ---------------------------------------------------------------------------

-- rapt_secret_id: FK auf vault.secrets, ON DELETE SET NULL (Vault-Row-Löschung
--   nullt automatisch die Referenz ohne die Profil-Row zu vernichten).
ALTER TABLE rapt.user_profiles
  ADD COLUMN IF NOT EXISTS rapt_secret_id uuid
    REFERENCES vault.secrets(id) ON DELETE SET NULL;

-- rapt_configured: generated boolean — Frontend sieht "configured?" ohne Decrypt-Recht.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'rapt'
      AND table_name   = 'user_profiles'
      AND column_name  = 'rapt_configured'
  ) THEN
    ALTER TABLE rapt.user_profiles
      ADD COLUMN rapt_configured boolean
        GENERATED ALWAYS AS (rapt_secret_id IS NOT NULL) STORED;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1b. id text → uuid (PK-Typ-Wechsel) + FK auf auth.users
--     Idempotent: prüft erst ob id noch text ist; wenn uuid, wird übersprungen.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_alex_id uuid;
  v_default_rapt_user_id text;
  v_default_rapt_api_key text;
BEGIN
  -- Nur ausführen wenn id noch vom Typ text ist
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'rapt'
      AND table_name   = 'user_profiles'
      AND column_name  = 'id'
      AND data_type    = 'text'
  ) THEN

    -- Alex' uuid aus auth.users holen
    SELECT id INTO v_alex_id
    FROM auth.users
    WHERE email = 'alex@alexstuder.ch';

    -- Bestands-Row 'default' auf Alex' uuid umschreiben (falls vorhanden UND uuid bekannt)
    IF v_alex_id IS NOT NULL THEN
      -- Daten retten bevor UPDATE (für spätere Vault-Migration in Step 3)
      SELECT rapt_user_id, rapt_api_key
        INTO v_default_rapt_user_id, v_default_rapt_api_key
      FROM rapt.user_profiles
      WHERE id = 'default';

      -- Row auf neue uuid umschreiben
      UPDATE rapt.user_profiles
      SET id = v_alex_id::text
      WHERE id = 'default';

      IF FOUND THEN
        RAISE NOTICE 'Datenmigration: ''default''-Row auf Alex uuid % umgeschrieben.', v_alex_id;
      ELSE
        RAISE NOTICE 'Keine ''default''-Row gefunden — No-op.';
      END IF;
    ELSE
      RAISE NOTICE 'alex@alexstuder.ch nicht in auth.users — ''default''-Row bleibt (wird in Step 3 übersprungen).';
    END IF;

    -- PK-Constraint droppen, Typ wechseln, neuen PK (uuid) anlegen
    ALTER TABLE rapt.user_profiles DROP CONSTRAINT user_profiles_pkey;
    ALTER TABLE rapt.user_profiles ALTER COLUMN id TYPE uuid USING id::uuid;
    ALTER TABLE rapt.user_profiles ADD PRIMARY KEY (id);

    -- FK auf auth.users anlegen (idempotent via constraint-Name-Prüfung weiter unten)
    ALTER TABLE rapt.user_profiles
      ADD CONSTRAINT user_profiles_id_fkey
        FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

    RAISE NOTICE 'id-Spalte auf uuid umgestellt + FK auf auth.users angelegt.';
  ELSE
    RAISE NOTICE 'id ist bereits uuid — Typ-Wechsel übersprungen.';
  END IF;
END $$;

-- Sicherheitshalber: FK-Constraint nochmals idempotent prüfen und ggf. anlegen
-- (falls Spalte schon uuid war, aber FK noch fehlte — z.B. bei partiell angewendeter Migration).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema    = 'rapt'
      AND table_name      = 'user_profiles'
      AND constraint_name = 'user_profiles_id_fkey'
      AND constraint_type = 'FOREIGN KEY'
  ) THEN
    ALTER TABLE rapt.user_profiles
      ADD CONSTRAINT user_profiles_id_fkey
        FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
    RAISE NOTICE 'FK user_profiles_id_fkey nachträglich angelegt.';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Klartext-Key → Vault migrieren
--    Nur Rows mit non-empty rapt_api_key UND rapt_secret_id IS NULL.
--    Idempotent: Bedingung verhindert Doppel-Migration.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
  v_secret_id uuid;
BEGIN
  FOR r IN
    SELECT id, rapt_user_id, rapt_api_key
    FROM rapt.user_profiles
    WHERE rapt_api_key IS NOT NULL
      AND rapt_api_key <> ''
      AND rapt_secret_id IS NULL
  LOOP
    v_secret_id := vault.create_secret(
      new_secret      => r.rapt_api_key,
      new_name        => 'rapt_dash_' || r.id::text,
      new_description => 'RAPT API key for user ' || r.id::text
    );
    UPDATE rapt.user_profiles
    SET rapt_secret_id = v_secret_id,
        rapt_api_key   = NULL
    WHERE id = r.id;
    RAISE NOTICE 'RAPT-Key für user % in Vault migriert: secret_id=%', r.id, v_secret_id;
  END LOOP;

  -- Klartext-Spalten nullen für Rows ohne Key (sauber, auch wenn schon NULL)
  UPDATE rapt.user_profiles
  SET rapt_api_key = NULL
  WHERE rapt_api_key IS NOT NULL AND rapt_secret_id IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 3. RLS aktivieren + Policies
-- ---------------------------------------------------------------------------
ALTER TABLE rapt.user_profiles ENABLE ROW LEVEL SECURITY;

-- SELECT: User sieht nur seine eigene Row
DROP POLICY IF EXISTS rapt_user_owns_profile_select ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_select
  ON rapt.user_profiles
  FOR SELECT
  TO authenticated
  USING (id = auth.uid());

-- INSERT: User darf nur Row mit seiner eigenen id einfügen
DROP POLICY IF EXISTS rapt_user_owns_profile_insert ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_insert
  ON rapt.user_profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (id = auth.uid());

-- UPDATE: User darf nur seine eigene Row ändern (USING verhindert Row-Sichtbarkeit für WHERE,
--         WITH CHECK verhindert, dass die Row nach UPDATE eine andere id bekommt).
DROP POLICY IF EXISTS rapt_user_owns_profile_update ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_update
  ON rapt.user_profiles
  FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- DELETE: User darf nur seine eigene Row löschen
DROP POLICY IF EXISTS rapt_user_owns_profile_delete ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_delete
  ON rapt.user_profiles
  FOR DELETE
  TO authenticated
  USING (id = auth.uid());

-- ---------------------------------------------------------------------------
-- 4. Grants korrigieren: anon-Grant zurückziehen, authenticated behalten (RLS mediiert)
-- ---------------------------------------------------------------------------
-- anon darf user_profiles nicht mehr lesen/schreiben (war offen aus 002_user_profiles.sql)
REVOKE SELECT, INSERT, UPDATE, DELETE ON rapt.user_profiles FROM anon;

-- authenticated behält SELECT/INSERT/UPDATE (RLS-mediiert); DELETE optional — Client löscht nicht
-- Explizit sicherstellen dass Grant korrekt gesetzt ist (war in 001 via GRANT ALL gesetzt)
GRANT SELECT, INSERT, UPDATE, DELETE ON rapt.user_profiles TO authenticated;
GRANT ALL ON rapt.user_profiles TO service_role;

-- ---------------------------------------------------------------------------
-- 5a. RPC: rapt.set_my_rapt_creds(p_rapt_user_id text, p_api_key text)
--     SECURITY DEFINER → läuft als supabase_admin (Vault-Owner)
--     SET search_path = '' → alle Objekte voll-qualifiziert, kein Schema-Injection
--     Interner auth.uid()-Filter → User kann nur eigene Creds setzen
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

  -- Sicherstellen, dass eine Profil-Row existiert (falls Trigger nicht gegriffen hat).
  -- Bewusst: 'name' (Anzeigename) wird hier mit dem RAPT-Username vorbelegt — COALESCE
  -- auf 'Brewer' als Fallback. Das ist gewollt, weil set_my_rapt_creds der einzige
  -- Code-Pfad ist, der den RAPT-Username kennt; der Trigger kennt ihn nicht.
  INSERT INTO rapt.user_profiles (id, name, updated_at)
  VALUES (v_uid, COALESCE(p_rapt_user_id, 'Brewer'), now())
  ON CONFLICT (id) DO NOTHING;

  -- Lese aktuellen secret_id für create-or-update
  SELECT up.rapt_secret_id INTO v_secret_id
  FROM rapt.user_profiles up
  WHERE up.id = v_uid;

  IF p_api_key IS NULL OR p_api_key = '' THEN
    -- Clear: secret_id nullen, Vault-Row löschen, rapt_user_id optional auch nullen
    IF v_secret_id IS NOT NULL THEN
      UPDATE rapt.user_profiles
      SET rapt_secret_id = NULL,
          rapt_user_id   = NULL,
          updated_at     = now()
      WHERE id = v_uid;
      DELETE FROM vault.secrets WHERE id = v_secret_id;
    ELSE
      -- Kein Key gesetzt, aber rapt_user_id ggf. zurücksetzen
      UPDATE rapt.user_profiles
      SET rapt_user_id = NULL,
          updated_at   = now()
      WHERE id = v_uid;
    END IF;
    RETURN;
  END IF;

  -- Key setzen (create-or-update im Vault)
  IF v_secret_id IS NULL THEN
    -- Neues Secret anlegen
    v_secret_id := vault.create_secret(
      new_secret      => p_api_key,
      new_name        => 'rapt_dash_' || v_uid::text,
      new_description => 'RAPT API key for user ' || v_uid::text
    );
    UPDATE rapt.user_profiles
    SET rapt_secret_id = v_secret_id,
        rapt_user_id   = p_rapt_user_id,
        rapt_api_key   = NULL,
        updated_at     = now()
    WHERE id = v_uid;
  ELSE
    -- Vorhandenes Secret updaten
    PERFORM vault.update_secret(
      secret_id  => v_secret_id,
      new_secret => p_api_key
    );
    UPDATE rapt.user_profiles
    SET rapt_user_id = p_rapt_user_id,
        rapt_api_key = NULL,
        updated_at   = now()
    WHERE id = v_uid;
  END IF;
END $$;

-- Grants für set_my_rapt_creds
REVOKE EXECUTE ON FUNCTION rapt.set_my_rapt_creds(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rapt.set_my_rapt_creds(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5b. RPC: rapt.get_my_rapt_creds()
--     SECURITY DEFINER → läuft als supabase_admin (kann vault.decrypted_secrets lesen)
--     SET search_path = '' → kein Schema-Injection
--     Interner auth.uid()-Filter → User sieht nur eigene Creds
--     Return-Shape: (username text, api_key text) — exakt was server.js getUserRaptCreds erwartet
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
    -- Keine Creds konfiguriert → leere Result-Menge
    RETURN;
  END IF;

  RETURN QUERY
    SELECT v_username, ds.decrypted_secret::text
    FROM vault.decrypted_secrets ds
    WHERE ds.id = v_secret_id;
END $$;

-- Grants für get_my_rapt_creds
REVOKE EXECUTE ON FUNCTION rapt.get_my_rapt_creds() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rapt.get_my_rapt_creds() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5c. Service-RPC: rapt.get_all_rapt_creds_for_sync()
--     SECURITY DEFINER → läuft als supabase_admin (Vault-Owner, bypass RLS)
--     SET search_path = '' → kein Schema-Injection
--
--     BEWUSST KEIN auth.uid()-Filter: Diese Funktion ist ausschliesslich für
--     den headless db-sync-Worker (brew-proxy), der mit der Rolle proxy_sync
--     verbindet und keinen User-JWT besitzt. Sie gibt ALLE konfigurierten
--     RAPT-Creds zurück, damit der Worker für jeden User Telemetrie pullen kann.
--
--     SICHERHEITSKRITISCH: Diese Funktion umgeht RLS und gibt Klartext-Keys aller
--     User zurück. EXECUTE ist AUSSCHLIESSLICH proxy_sync erlaubt.
--     PUBLIC / anon / authenticated sind explizit revoked.
--
--     Return-Shape: (owner uuid, rapt_user_id text, rapt_api_key text)
--     — der owner-Wert wird in Phase 2 genutzt, um Telemetrie zu stempeln.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.get_all_rapt_creds_for_sync()
RETURNS TABLE (owner uuid, rapt_user_id text, rapt_api_key text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- KEIN auth.uid()-Filter: headless Worker, kein User-JWT. Bewusste, einzige
  -- Ausnahme vom Tenant-Filter-Gebot — abgesichert durch:
  --   1. EXECUTE nur für proxy_sync (minimalprivilegierte Rolle, kein BYPASSRLS)
  --   2. SECURITY DEFINER läuft als supabase_admin (Vault-Owner)
  --   3. Kein direkter Vault-Tabellenzugriff für proxy_sync — nur diese Funktion
  RETURN QUERY
    SELECT
      up.id                       AS owner,
      up.rapt_user_id             AS rapt_user_id,
      ds.decrypted_secret::text   AS rapt_api_key
    FROM rapt.user_profiles up
    JOIN vault.decrypted_secrets ds ON ds.id = up.rapt_secret_id
    WHERE up.rapt_secret_id IS NOT NULL;
END $$;

-- Grants: STRIKT nur proxy_sync. PUBLIC/anon/authenticated explizit revoked.
REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 6. proxy_sync-Grants umstellen (Vault-Schuld aus 004/005 tilgen)
--    Der Worker liest Creds nicht mehr direkt aus der Tabelle (Klartext-Spalten
--    sind jetzt NULL + RLS aktiv). Stattdessen: ausschliesslich via Service-RPC.
--    Übrige proxy_sync-Grants (controllers/hydrometers/profiles/telemetry/brew_sessions)
--    bleiben unverändert — Phase 1 fasst Telemetrie nicht an.
-- ---------------------------------------------------------------------------
REVOKE SELECT ON rapt.user_profiles FROM proxy_sync;
-- GRANT EXECUTE auf Service-RPC ist bereits in 5c gesetzt.

COMMENT ON ROLE proxy_sync IS
  'Minimal-privilegierte Rolle für den brew-proxy db-sync-Worker. '
  'Darf ausschliesslich rapt.*-Tabellen lesen/schreiben. '
  'Kein BYPASSRLS, kein Zugriff auf aibrewgenius.*/auth.*/vault.*. '
  'Passwort wird via zz-set-role-passwords.sh mit dedizierter PROXY_SYNC_PASSWORD-Variable gesetzt '
  '(NICHT ${POSTGRES_PASSWORD} — geteiltes Master-Passwort hebt least-privilege auf). '
  'Eingeführt in Migration 004 (Phase 1 Multi-VPS); Grants korrigiert in 005. '
  'Ab rapt/004_rapt_user_vault.sql: kein direkter SELECT auf rapt.user_profiles mehr; '
  'RAPT-Creds nur noch via SECURITY DEFINER rapt.get_all_rapt_creds_for_sync(). '
  'Vault-Schuld aus aibrewgenius/004_proxy_role.sql + 005_fix_proxy_role_grants.sql getilgt.';

-- ---------------------------------------------------------------------------
-- 7. Trigger: rapt.handle_new_user() — Auto-Insert bei neuem auth.users
--    Anlegen einer rapt.user_profiles-Row bei jedem neuen auth-User, damit
--    BC1/BC4-User (RAPT-Dashboard standalone) sofort eine Profil-Row haben.
--    ON CONFLICT DO NOTHING = idempotent (mehrfacher Trigger-Lauf oder manuell
--    vorab angelegte Rows werfen keinen Fehler).
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
    COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1), 'Brewer'),
    now()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END $$;

-- Trigger auf auth.users: AFTER INSERT, pro Row
DROP TRIGGER IF EXISTS on_rapt_user_created ON auth.users;
CREATE TRIGGER on_rapt_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION rapt.handle_new_user();

-- Postgres grantet EXECUTE per Default an PUBLIC, auch für Trigger-Funktionen.
-- Explizit entziehen — analog zu den drei RPCs oben.
REVOKE EXECUTE ON FUNCTION rapt.handle_new_user() FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Index: rapt_secret_id (FK-Spalte, für RLS-Policy/JOIN-Performance)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_user_profiles_rapt_secret_id
  ON rapt.user_profiles (rapt_secret_id)
  WHERE rapt_secret_id IS NOT NULL;

COMMIT;

-- =============================================================================
-- Sanity Checks (read-only, ausserhalb der Transaktion)
-- =============================================================================
\echo ''
\echo '== rapt.user_profiles Struktur =='
\d rapt.user_profiles

\echo ''
\echo '== user_profiles Daten (rapt_api_key soll NULL sein) =='
SELECT
  id,
  name,
  rapt_user_id,
  rapt_api_key IS NULL        AS api_key_nulled,
  rapt_secret_id IS NOT NULL  AS in_vault,
  rapt_configured,
  updated_at
FROM rapt.user_profiles;

\echo ''
\echo '== Vault-Inhalt (rapt-Keys) =='
SELECT name, description, created_at FROM vault.secrets WHERE name LIKE 'rapt_dash_%';

\echo ''
\echo '== RLS-Status =='
SELECT tablename, rowsecurity FROM pg_tables
WHERE schemaname = 'rapt' AND tablename = 'user_profiles';

\echo ''
\echo '== Policies auf rapt.user_profiles =='
SELECT policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname = 'rapt' AND tablename = 'user_profiles';

\echo ''
\echo '== Funktionen im rapt-Schema =='
SELECT proname, prosecdef, proconfig
FROM pg_proc
WHERE pronamespace = 'rapt'::regnamespace
ORDER BY proname;

\echo ''
\echo '== proxy_sync Grants auf rapt.user_profiles (soll leer sein nach 004) =='
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'proxy_sync'
  AND table_schema = 'rapt'
  AND table_name = 'user_profiles';

\echo ''
\echo '== proxy_sync Function-Grants (soll get_all_rapt_creds_for_sync enthalten) =='
SELECT grantee, routine_schema, routine_name, privilege_type
FROM information_schema.role_routine_grants
WHERE grantee = 'proxy_sync' AND routine_schema = 'rapt';

\echo ''
\echo '== Trigger auf auth.users (soll on_rapt_user_created enthalten) =='
SELECT tgname, tgrelid::regclass, tgfoid::regproc
FROM pg_trigger
WHERE tgrelid = 'auth.users'::regclass
  AND tgname IN ('on_auth_user_created', 'on_rapt_user_created');
