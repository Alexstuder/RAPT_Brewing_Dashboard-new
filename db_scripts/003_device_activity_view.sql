-- Aggregierte Sicht auf Controller-Telemetrie pro Profile (auch NULL).
-- Wird von der DeviceDetailsPage genutzt um die Aktivitäts-Timeline anzuzeigen.

CREATE OR REPLACE VIEW rapt.device_activity_controllers AS
SELECT
  t.device_id,
  t.profile_id,
  p.name AS profile_name,
  MIN(t.created_on) AS first_seen,
  MAX(t.created_on) AS last_seen,
  COUNT(*)::int AS point_count
FROM rapt.telemetry_controllers t
LEFT JOIN rapt.profiles p ON p.id = t.profile_id
GROUP BY t.device_id, t.profile_id, p.name;

GRANT SELECT ON rapt.device_activity_controllers TO anon, authenticated, service_role;
