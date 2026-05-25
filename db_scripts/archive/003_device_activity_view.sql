-- Aggregierte Sicht auf Controller-Telemetrie pro Profile + Gap-Split (>7 Tage).
-- Damit eine RAPT-Profile-Wiederverwendung mit zeitlichen Lücken als mehrere
-- separate Phasen erscheint (z.B. 2x "London Pride" mit Monaten dazwischen).
-- NULL-profile (unzugeordnet) wird NICHT gesplittet weil prev nur über
-- gleiches profile_id schaut — null läuft als ein großer Block.

CREATE OR REPLACE VIEW rapt.device_activity_controllers AS
WITH ordered AS (
  SELECT device_id, created_on, profile_id,
         LAG(created_on) OVER (PARTITION BY device_id, profile_id ORDER BY created_on) AS prev
  FROM rapt.telemetry_controllers
),
marked AS (
  SELECT device_id, created_on, profile_id,
    SUM(CASE WHEN prev IS NULL OR created_on - prev > INTERVAL '7 days' THEN 1 ELSE 0 END)
      OVER (PARTITION BY device_id, profile_id ORDER BY created_on) AS sess_n
  FROM ordered
)
SELECT
  m.device_id,
  m.profile_id,
  p.name AS profile_name,
  m.sess_n AS session_index,
  MIN(m.created_on) AS first_seen,
  MAX(m.created_on) AS last_seen,
  COUNT(*)::int AS point_count
FROM marked m
LEFT JOIN rapt.profiles p ON p.id = m.profile_id
GROUP BY m.device_id, m.profile_id, p.name, m.sess_n;

GRANT SELECT ON rapt.device_activity_controllers TO anon, authenticated, service_role;
