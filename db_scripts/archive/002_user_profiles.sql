-- ============================================================================
-- rapt.user_profiles — RAPT-Dashboard-spezifischer User-Kontext
-- (Sudgröße + Brewfather-Creds gehören zu brew_assistent, nicht hier).
-- Single-user jetzt, multi-user-ready (id wird später auth.users.id::text).
-- ============================================================================

CREATE TABLE IF NOT EXISTS rapt.user_profiles (
  id           text PRIMARY KEY,         -- jetzt 'default', später auth.users.id
  name         text NOT NULL,
  avatar_blob  text,                     -- base64-encoded image
  rapt_user_id text,
  rapt_api_key text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON rapt.user_profiles TO anon, authenticated;
GRANT ALL ON rapt.user_profiles TO service_role;
