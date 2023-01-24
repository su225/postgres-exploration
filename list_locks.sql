create view locks as
select pid, locktype,
  case locktype
    when 'relation' then relation::regclass::text
    when 'transactionid' then transactionid::text
    when 'virtualxid' then virtualxid
  end as lockid,
  mode,
  granted
from pg_locks
order by 1,2,3;