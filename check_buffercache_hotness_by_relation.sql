SELECT 
  c.relname,
  count(*) blocks,
  round( 100.0 * 8192 * count(*) / pg_table_size(c.oid) ) AS "% of rel", -- % of relation cached and actively used
  round( 100.0 * 8192 * count(*) FILTER (WHERE b.usagecount > 1) / pg_table_size(c.oid) ) AS "% hot"
FROM pg_buffercache b
JOIN pg_class c 
  ON pg_relation_filenode(c.oid) = b.relfilenode
WHERE b.reldatabase IN (
  0, -- cluster-wide objects
  (SELECT oid 
   FROM pg_database 
   WHERE datname = current_database()))
AND b.usagecount IS NOT NULL
GROUP BY c.relname, c.oid
ORDER BY 2 DESC
LIMIT 10;