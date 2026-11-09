-- Q4. Per week, how many planned sessions were done, missed or still to come, and what was done unplanned?
-- From plan_vs_actual (every plan file, matched by sport and day). Weeks run Monday to Sunday.
WITH unplanned AS (
  SELECT date(a.start_local, '-' || ((CAST(strftime('%w', a.start_local) AS INT) + 6) % 7) || ' days') AS week,
         COUNT(*) AS n, GROUP_CONCAT(substr(a.start_local, 6, 5) || ' ' || a.sport, ', ') AS what
    FROM activity a
   WHERE a.sport <> 'mobility' AND a.start_local >= (SELECT MIN(date) FROM planned_session)
     AND a.id NOT IN (SELECT activity_id FROM planned_session WHERE activity_id IS NOT NULL)
   GROUP BY 1)
SELECT p.week, COUNT(*) AS planned,
       SUM(status = 'done') AS done, SUM(status = 'missed') AS missed,
       SUM(status = 'upcoming') AS upcoming, SUM(status = 'cancelled') AS cancelled,
       GROUP_CONCAT(CASE WHEN status = 'missed' THEN weekday || ' ' || title END, '; ') AS missed_sessions,
       COALESCE(u.n, 0) AS unplanned, u.what AS unplanned_sessions
  FROM plan_vs_actual p LEFT JOIN unplanned u USING (week)
 GROUP BY p.week ORDER BY p.week;
