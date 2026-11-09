-- Q5. How much of the training plan rests on strong evidence? Claims used by a plan rule,
-- by computed strength, with how many sources stand behind them and how many have none.
WITH c AS (
  SELECT e.claim_id, e.strength, COUNT(cs.source_id) AS sources
    FROM evidence_claim e LEFT JOIN evidence_claim_source cs USING (claim_id)
   WHERE COALESCE(e.used_in, '') <> ''
   GROUP BY e.claim_id
)
SELECT strength, COUNT(*) AS claims,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM c)) AS pct,
       ROUND(AVG(sources), 1) AS avg_sources,
       SUM(sources = 0) AS no_source
  FROM c
 GROUP BY strength
 ORDER BY CASE strength WHEN 'High' THEN 1 WHEN 'Moderate' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END;
