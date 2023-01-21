# Write-Ahead logging
This is necessary to ensure durability. But it has a performance cost. The rule is: the write to the pages in the buffercache does not hit the disk until the corresponding WAL entry is flushed to disk. Also, the commit must hit the disk before acknowledging the transaction for durability. Another performance tradeoff of asynchronous commit is possible at the cost of durability (relaxed ACID semantics).

## Physical structure
* WAL files are located in `$PGDATA/pg_wal` directory. 
* The tail of the WAL flushed to disk can be accessed by `pg_current_wal_lsn()`
* The head of the WAL where new entries would be inserted is `pg_current_insert_wal_lsn()`
* Because postgres has to make sure that the buffer cache pages should have corresponding WAL entries saved to disk, each page keeps track of `lsn` in the page header and this can be accessed as `select lsn from page_header(get_raw_page(relation, blocknum))` where `relation` could be either a table or an index.
* WAL entry length can be accessed by `select to_wal::pg_lsn - from_wal::pg_lsn;`
* We can query which file a particular entry is located through
  ```sql
  select
    file_name,
    upper(to_hex(file_offset)) as file_offset
  from pg_walfile_name_offset('0/3E744260')
  ```
* We can use `pg_ls_waldir()` to list all WAL files. This can be remembered as `ls -l $PGDATA/pg_wal`.
* The utility `pg_waldump` can be used to print the WAL entries in a human friendly manner for a given offset or from a given transaction.

## Checkpointing
This is to speed up the recovery. Theoretically, Postgres can just iterate through the log from start to finish to reconstruct the database cluster state fully. But practically, that would be too slow and does not scale well. So, periodically we should **checkpoint** to make sure that we can start recovery from there. It also has the advantage that we can truncate all the entries in the WAL before that point so that we can prevent WAL from growing indefinitely and consuming all the disk space.

It is possible to periodically suspend all the operations to create a checkpoint of the database state. But that is unacceptable. So, it is spread over. The checkpointer first logs CLOG (commit log) transaction status, subtransactions' metadata and a few other structures in a phase called **checkpoint start**. Then the next phase is **checkpoint execution** where pages which have their LSN before the checkpoint start are flushed to disk.

Now, that raises the question of "what if the pages which were dirty with LSN before checkpoint start were updated so that the LSN falls after as not flushing this could result in losing changes". The answer to this is that **a special tag** is set in the buffercache header of all the dirty pages that were modified before the start of the checkpoint. This marks all the pages that are not supposed to be touched before flushing changes to the disk. Then checkpointer traverses all the buffers and writes the tagged ones to disk. Their pages are not evicted from the cache. If the backend gets to such pages before then it can flush the changes before writing the newly dirtied page. So backend has to know that a checkpoint is being done and also the LSN ID of the checkpoint start so that it can flush.

**Checkpoint completion** is the phase where all the buffers that were dirty at the start of the checkpoint are written to disk and the checkpoint is considered complete. From now on, the start of the checkpoint is used as the new recovery point. How? It is the typical ARIES algorithm. On recovery, we load the CLOG and subtransaction state that was there at the start, then replay all the WAL records till the end to apply all the changes. In the end, we will get to know which transactions were not committed and they all are aborted. Since postgres does not modify any tuple in place, we do not need to revert changes in individual pages as updating transaction status would be enough. Otherwise, we should keep the first LSN of each of the ongoing transactions and traverse all the way till there which could be even before **checkpoint start** - i.e postgres design does not require undo.

The `$PGDATA/global/pg_control` gets updated to point to the latest checkpoint. What if **checkpoint complete** is written and the database crashed before updating `pg_control` file? The database would pick from the previous snapshot which is still ok although it could take a bit longer to recover from the crash. Truncating is only safe after updating `pg_control` file. Otherwise, we would land in a situation where the database wants to start recovery from an LSN which is already gone which could lead to possible data loss or corruption as it cannot know what transactions should be aborted or committed.

Checkpoint can be triggered manually with `checkpoint` command.

## Recovery from checkpoint
The recovery starts from the **checkpoint start** recorded as redo LSN in the **checkpoint end** as recorded in `pg_control` which can be viewed through the `pg_controldata` utility. The WAL entries could be either **full page image** which are idempotent or not. While applying the WAL entries care should be taken to make sure that the last LSN for the page is less than the recovery start LSN or else it must not apply. Also, transaction status in CLOG bits are also applied idempotently. Files are also restored in a similar manner - if the WAL entry shows that the file should have existed, but it is not, then it is created. Same with deletions.

## Background writing
`bgwriter` process is responsible for flushing unpinned dirty pages with usage count 0 to disk. It maintains its own clock hand and the usage count of buffers is not reduced as it traverses. Typically, it overtakes the eviction clock hand. The purpose is to raise the odds of the pages to be evicted to be clean so that the backend does not need to wait for flushing to disk when it needs to evict a page from the buffercache.

## WAL tuning parameters
* `checkpoint_timeout` - time period after which checkpoints are invoked
* `max_wal_size` - when the WAL size approaches this size, a checkpoint is triggered even if `checkpoint_timeout` has not yet elapsed. Frequent checkpoints could mean lower `checkpoint_timeout` or `max_wal_size` or both. Keep in mind that while checkpointing reduces the time to recovery, it has I/O overhead as it has to locate and write dirty buffers to disk.
* `checkpoint_warning` - if checkpoints happen closer together than the seconds configured then a warning is printed. Bulk operations like copy can trigger a lot of WAL writing and checkpoints. So there could be false alarms.
* `checkpoint_completion_target` is the fraction of `checkpoint_timeout` (usually 0.9) which is used to control the disk I/O rate which is one of the biggest costs in checkpointing. It is the fraction of time set through `checkpoint_timeout` which is the target to complete the checkpointing task.
* `wal_min_files` is the number of WAL files kept for reuse instead of deleting. This reduces the overhead of constantly creating and deleting files, but instead they are just reused. This requires `wal_recycle` parameter to be turned on.

## Configuring background writer
* `bgwriter_delay` - sleeps for the interval specified before scanning and writing dirty buffers to disk.
* `bgwriter_lru_maxpages` - the number of processed buffers after `bgwriter_delay`.
* `bgwriter_lru_multiplier` - the number of dirty buffers written depends on the average number of buffers accessed by the backends. Postgres uses a moving average of recently calculated numbers. Then it is multiplied by `bgwriter_lru_multiplier` factor and this is the upper limit of the number of buffers that the bgwriter is allowed to flush to disk in this iteration. If there are not enough buffers to flush, then it goes to sleep and wakes up when a backend accesses one. Naturally, setting a lower multiplier could limit the number of buffers that could be flushed and hence many dirty buffers could remain during periods of heavy load. On the other hand, flushing also incurs I/O costs that need to be balanced with heavy writing.

## Monitoring and configuration
`pg_stat_bgwriter` and `pg_stat_wal` contain a wealth of information to monitor the activities of background writer and WAL.

In `pg_stat_bgwriter` table.
* `checkpoints_timed` is the number of periodic checkpoints invoked by `checkpoint_timeout`
* `checkpoints_req` is the number of on-demand checkpoints triggered by `CHECKPOINT` command and `max_wal_size` parameter. This could be concerning if it is high because it means postgres cannot checkpoint periodically and accumulating a lot of WAL also means high chances of having many dirty buffers and the system having to endure high I/O. Also, if the `checkpoint_completion_target` is 1 or above, checkpoint won't be completed on time. In this case, postgres thinks it is falling behind and ignores the I/O spacing parameter (a.k.a completion target) and does lots of I/O and starts another checkpoint. This is pretty bad for system performance as it leads to many I/O cycles being stolen for checkpointing.
* `maxwritten_clean` is the number of times bgwriter stopped because maxpages was exceeded. If this is a lot then the `bgwriter_lru_maxpages` parameter must be bumped.
* `buffers_checkpoint` is the pages written by the checkpointer.
* `buffers_backend` is the pages written by the backend. This must be as low as possible.
* `buffers_backend_fsync` is the number of times backends are forced to make `fsync` requests. Any non-zero value shows problems when the fsync queue is filled.
* `buffers_clean` is the pages written by bgwriter. This must be higher.
* `buffers_alloc` is the number of buffers allocated.

After changing settings, the statistics could be reset with `pg_stat_reset_shared('bgwriter')` function.

`pg_stat_wal` provides a lot of useful information on WAL and the writing rate.
* `wal_records` is the number of WAL records generated so far.
* `wal_fpi` is the number of full page images generated. By default, full-page images are generated for a modification of a page immediately after taking the snapshot. This is because it is possible that the non-atomic page write (while flushing to disk) could corrupt the page because at the filesystem level, the I/O unit could be much smaller (like 512B instead of 8KB). Applying WAL changes to corrupt pages could lead to data corruption and possibly data loss. Hence, the full page image is included so that it can be restored during recovery even if the page is corrupt due to non-atomic update. However, this comes at a cost of a longer WAL entry as the full page needs to be written. In fact, when checkpoints are frequent, not only the I/O costs of flushing data pages to the disk, but also the WAL gets much bigger.
* `wal_bytes` is the total number of WAL bytes generated. The rate of change would indicate the WAL related I/O costs.
* `wal_buffers_full` is the total number of times the WAL buffers had to be written to disk because they became full.
* `wal_write` and `wal_sync` is the counter of number of times WAL records had to be written to disk and `fsync` to be called respectively. The corresponding time is measured by `wal_write_time` and `wal_sync_time` parameters.
* `stats_reset` is the time at which these stats were reset. These are counters which are supposed to be monotonically increasing assuming that resets don't happen. Hence, the monitoring systems like Prometheus are supposed to treat them as such.

`XLogWrite` is the WAL function which writes WAL data to disk. It is normally called by `XLogInsertRecord` and `XLogFlush` and the WAL writer background process to write WAL buffers to disk and call `issue_xlog_fsync` to sync WAL files to disk. If `wal_sync_method` is either `open_datasync` or `open_sync` then write in `XLogWrite` is guaranteed to write to disk because the WAL files are opened with `O_DIRECT` flag instead of moving to the kernel cache. In this case, `fsync` call is not needed.