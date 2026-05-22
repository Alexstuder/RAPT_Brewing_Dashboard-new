-- ============================================================================
-- rapt.user_profiles — single-user jetzt, multi-user-ready vom Schema her
-- (id ist text damit später auth.users.id::text reingeschoben werden kann).
-- ============================================================================

CREATE TABLE IF NOT EXISTS rapt.user_profiles (
  id                       text PRIMARY KEY,         -- jetzt 'default', später auth.users.id
  name                     text NOT NULL,
  avatar_blob              text,                     -- base64-encoded image
  default_batch_liters     double precision,
  rapt_user_id             text,
  rapt_api_key             text,
  brewfather_user_id       text,
  brewfather_api_key       text,
  brewfather_sync_enabled  boolean DEFAULT false,
  updated_at               timestamptz NOT NULL DEFAULT now()
);

-- Berechtigungen (single-user Pattern: anon = ALL).
-- Bei Multi-User später: anon zurück auf SELECT, RLS-Policies auf user_id = auth.uid().
GRANT SELECT, INSERT, UPDATE, DELETE ON rapt.user_profiles TO anon, authenticated;
GRANT ALL ON rapt.user_profiles TO service_role;
