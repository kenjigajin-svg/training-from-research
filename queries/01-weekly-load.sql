-- Q1. Weekly training load by sport over the last 12 months, and where were the gaps?
-- Load = Banister TRIMP per activity (activity_load), summed per week (Monday date) and sport group.
WITH w AS (
  SELECT date(a.start_local, '-6 days', 'weekday 1') AS week,
         CASE WHEN a.sport IN ('muay_thai','cardio') THEN 'combat/cardio'
              WHEN a.sport IN ('walking','mobility','stairs') THEN 'other'
              ELSE a.sport END AS sport,
         l.load
    FROM activity a JOIN activity_load l ON l.activity_id = a.id
   WHERE a.start_local >= date('now', '-12 months') AND l.load IS NOT NULL
)
SELECT week,
       ROUND(SUM(load)) AS total,
       ROUND(SUM(CASE WHEN sport='cycling' THEN load END)) AS cycling,
       ROUND(SUM(CASE WHEN sport='running' THEN load END)) AS running,
       ROUND(SUM(CASE WHEN sport='strength' THEN load END)) AS strength,
       ROUND(SUM(CASE WHEN sport='swimming' THEN load END)) AS swimming,
       ROUND(SUM(CASE WHEN sport='combat/cardio' THEN load END)) AS combat,
       ROUND(SUM(CASE WHEN sport='other' THEN load END)) AS other
  FROM w GROUP BY week ORDER BY week;
