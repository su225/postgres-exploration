select 
  a.attname,
  s.stanullfrac
from pg_statistic s 
  inner join pg_attribute a 
  on s.staattnum = a.attnum 
    and s.starelid = a.attrelid
where s.starelid = 'flights_copy'::regclass::oid 
and not a.attnotnull;