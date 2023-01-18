/* check the number of buffers occupied by a relation (table, index etc) 
 * please note that index, table and toast table/index must be considered
 * separately as the buffercache does not treat them as the same. For the
 * buffercache is at a much lower level than the table abstraction which
 * consists of indexes, toast tables and its indexes etc.
 */
SELECT relfilenode, count(*)
FROM pg_buffercache
WHERE relfilenode IN (
  pg_relation_filenode('big'),
  pg_relation_filenode('big_pkey')
)
GROUP BY relfilenode;