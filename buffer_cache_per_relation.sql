CREATE FUNCTION buffercache(rel regclass)
RETURNS TABLE(
  bufferid integer,
  relfork text,
  relblk bigint,
  isdirty boolean,
  usagecount smallint,
  pins integer
) AS $$
  SELECT
    bufferid,
    CASE relforknumber
      WHEN 0 THEN 'main'
      WHEN 1 THEN 'fsm'
      WHEN 2 THEN 'vm'
    END,
    relblocknumber,
    isdirty,
    usagecount,
    pinning_backends
  FROM pg_buffercache
  WHERE relfilenode = pg_relation_filenode(rel)
  ORDER BY relforknumber, relblocknumber;
$$ LANGUAGE sql;