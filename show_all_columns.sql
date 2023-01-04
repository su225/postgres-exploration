-- Reads all columns from the database for a given relation
-- and pretty prints output for deducing the tuple layout
DROP FUNCTION IF EXISTS get_columns;
CREATE FUNCTION get_columns(relname TEXT)
  RETURNS TABLE(
    colname NAME,
    colnum SMALLINT,
    coltype REGTYPE,
    len TEXT,
    alignment INT,
    storage TEXT
  )
AS $$
BEGIN
  RETURN QUERY SELECT
    a.attname AS colname,  -- the name of the column
    a.attnum AS colnum,   -- the position of the column within the tuple
    a.atttypid::OID::REGTYPE AS coltype, -- datatype of the column
    CASE
      WHEN a.attlen = -1 THEN 'var'
      ELSE a.attlen::TEXT
    END AS len,
    CASE
      WHEN a.attalign = 'c' THEN 1
      WHEN a.attalign = 's' THEN 2
      WHEN a.attalign = 'i' THEN 4
      WHEN a.attalign = 'd' THEN 8
    END AS alignment,
    -- a.attstorage AS storage
    CASE
      WHEN a.attstorage = 'p' THEN 'plain'
      WHEN a.attstorage = 'x' THEN 'extended'
      WHEN a.attstorage = 'e' THEN 'external'
      WHEN a.attstorage = 'm' THEN 'main'
    END AS storage
  FROM pg_attribute AS a
  WHERE a.attrelid = relname::REGCLASS
  AND a.attnum > 0
  ORDER BY a.attnum;
END; $$

LANGUAGE 'plpgsql';