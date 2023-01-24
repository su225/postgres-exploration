create function row_locks(relname text, pageno integer)
returns table(
  ctid tid,
  xmax text,
  lock_only text,
  is_multi text,
  keys_upd text,
  keyshr text,
  shr text
)
as $$
select (pageno,lp)::text::tid,
  t_xmax,
  case when t_infomask & 128 = 128 then 't' end,
  case when t_infomask & 4096 = 4096 then 't' end,
  case when t_infomask2 & 8192 = 8192 then 't' end,
  case when t_infomask & 16 = 16 then 't' end,
  case when t_infomask & 16+64 = 16+64 then 't' end
from heap_page_items(get_raw_page(relname, pageno))
order by lp;
$$ language sql;