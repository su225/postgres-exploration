/* Calculate hit ratio for a table in postgres */
select
  relname,
  case
    when heap_blks_read > 0 then 
      trunc(((1.0 * heap_blks_hit/(heap_blks_hit + heap_blks_read)) * 100.0)::decimal, 2)::text || '%'
    else 'not_read'
  end as heap_hit_ratio,
  case
    when idx_blks_read > 0 then
      trunc(((1.0 * idx_blks_hit/(idx_blks_hit + idx_blks_read)) * 100.0)::decimal, 2)::text || '%'
    else 'not_read'
  end as index_hit_ratio,
  case
    when toast_blks_read > 0 then
      trunc(((1.0 * toast_blks_hit/(toast_blks_hit + toast_blks_read)) * 100.0)::decimal, 2)::text || '%'
    else 'not_read'
  end as toast_hit_ratio,
  case
    when tidx_blks_read > 0 then
      trunc(((1.0 * tidx_blks_hit/(tidx_blks_hit + tidx_blks_read)) * 100.0)::decimal, 2)::text || '%'
    else 'not_read'
  end as tidx_hit_ratio 
from pg_statio_all_tables
where relname = 'cacheme'
  and schemaname = 'public';