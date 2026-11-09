-- Q3. Which weeks were monotonous or high strain? Foster 1998: monotony = mean daily load /
-- SD of daily load over the week (rest days count as 0); strain = weekly load x monotony.
WITH days AS (
  SELECT date, load, date(date, '-6 days', 'weekday 1') AS week FROM fitness_day
   WHERE date >= date('now', '-12 months')
), wk AS (
  SELECT week, COUNT(*) AS n, SUM(load) AS total, AVG(load) AS mean,
         SQRT(AVG(load*load) - AVG(load)*AVG(load)) AS sd
    FROM days GROUP BY week HAVING n = 7
)
SELECT week, ROUND(total) AS weekly_load, ROUND(mean / NULLIF(sd,0), 2) AS monotony,
       ROUND(total * mean / NULLIF(sd,0)) AS strain
  FROM wk ORDER BY strain DESC LIMIT 10;
