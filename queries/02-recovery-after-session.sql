-- Q2. Resting HR and HRV the morning after Muay Thai, versus after an easy run or a rest day.
-- "Morning after" = the daily row dated the next day. Easy run = running with average HR
-- under 150 and nothing harder that day. Rest day = no activity (walks and mobility aside).
WITH day_kind AS (
  SELECT d.date,
         CASE
           WHEN EXISTS (SELECT 1 FROM activity a WHERE substr(a.start_local,1,10)=d.date
                        AND a.sport='muay_thai')
             THEN 'muay thai'
           WHEN EXISTS (SELECT 1 FROM activity a WHERE substr(a.start_local,1,10)=d.date
                        AND a.sport='running' AND a.avg_hr < 150)
            AND NOT EXISTS (SELECT 1 FROM activity a WHERE substr(a.start_local,1,10)=d.date
                        AND a.sport NOT IN ('running','walking','mobility'))
             THEN 'easy run only'
           WHEN NOT EXISTS (SELECT 1 FROM activity a WHERE substr(a.start_local,1,10)=d.date
                        AND a.sport NOT IN ('walking','mobility'))
             THEN 'rest day'
         END AS kind
    FROM daily d
)
SELECT k.kind, COUNT(*) AS nights,
       ROUND(AVG(n.resting_hr),1) AS resting_hr_next_morning,
       ROUND(AVG(n.hrv_ms),1) AS hrv_next_morning,
       ROUND(AVG(n.sleep_s)/3600.0,1) AS sleep_h
  FROM day_kind k JOIN daily n ON n.date = date(k.date, '+1 day')
 WHERE k.kind IS NOT NULL AND n.resting_hr IS NOT NULL
 GROUP BY k.kind ORDER BY resting_hr_next_morning DESC;
