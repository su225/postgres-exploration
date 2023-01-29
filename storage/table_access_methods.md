# Table access methods
Postgres storage engines are pluggable. They are stored in `pg_am` catalog table. By default, only `heap` is installed out of the box. The storage engines have to define the following
* tuple format and data structure
* table scan implementation and cost estimation
* implementation of insert, update, delete and lock operations
* visibility rules for MVCC
* vacuum and analysis procedures

They can use the following subsystems in postgres
* transaction manager, including ACID and snapshot isolation support
* buffer manager (buffercache stuff)
* I/O subsystem
* TOAST
* optimizer and executor
* index support

However, the interface keeps changing. It is still unclear how to deal with the WAL. New access methods may need to write their own operations that the core is unaware of. The existing generic WAL mechanism may incur too much overhead. On the other hand, abstracting it and depending on 3rd party code for recovery is worrying. Unfortunately, the only plausible solution seems to be patching the core to add new access methods.

Here are the access method definitions for the heap.
```c
/* ------------------------------------------------------------------------
 * Definition of the heap table access method.
 * ------------------------------------------------------------------------
 */

static const TableAmRoutine heapam_methods = {
	.type = T_TableAmRoutine,

	.slot_callbacks = heapam_slot_callbacks,

	.scan_begin = heap_beginscan,
	.scan_end = heap_endscan,
	.scan_rescan = heap_rescan,
	.scan_getnextslot = heap_getnextslot,

	.scan_set_tidrange = heap_set_tidrange,
	.scan_getnextslot_tidrange = heap_getnextslot_tidrange,

	.parallelscan_estimate = table_block_parallelscan_estimate,
	.parallelscan_initialize = table_block_parallelscan_initialize,
	.parallelscan_reinitialize = table_block_parallelscan_reinitialize,

	.index_fetch_begin = heapam_index_fetch_begin,
	.index_fetch_reset = heapam_index_fetch_reset,
	.index_fetch_end = heapam_index_fetch_end,
	.index_fetch_tuple = heapam_index_fetch_tuple,

	.tuple_insert = heapam_tuple_insert,
	.tuple_insert_speculative = heapam_tuple_insert_speculative,
	.tuple_complete_speculative = heapam_tuple_complete_speculative,
	.multi_insert = heap_multi_insert,
	.tuple_delete = heapam_tuple_delete,
	.tuple_update = heapam_tuple_update,
	.tuple_lock = heapam_tuple_lock,

	.tuple_fetch_row_version = heapam_fetch_row_version,
	.tuple_get_latest_tid = heap_get_latest_tid,
	.tuple_tid_valid = heapam_tuple_tid_valid,
	.tuple_satisfies_snapshot = heapam_tuple_satisfies_snapshot,
	.index_delete_tuples = heap_index_delete_tuples,

	.relation_set_new_filelocator = heapam_relation_set_new_filelocator,
	.relation_nontransactional_truncate = heapam_relation_nontransactional_truncate,
	.relation_copy_data = heapam_relation_copy_data,
	.relation_copy_for_cluster = heapam_relation_copy_for_cluster,
	.relation_vacuum = heap_vacuum_rel,
	.scan_analyze_next_block = heapam_scan_analyze_next_block,
	.scan_analyze_next_tuple = heapam_scan_analyze_next_tuple,
	.index_build_range_scan = heapam_index_build_range_scan,
	.index_validate_scan = heapam_index_validate_scan,

	.relation_size = table_block_relation_size,
	.relation_needs_toast_table = heapam_relation_needs_toast_table,
	.relation_toast_am = heapam_relation_toast_am,
	.relation_fetch_toast_slice = heap_fetch_toast_slice,

	.relation_estimate_size = heapam_estimate_rel_size,

	.scan_bitmap_next_block = heapam_scan_bitmap_next_block,
	.scan_bitmap_next_tuple = heapam_scan_bitmap_next_tuple,
	.scan_sample_next_block = heapam_scan_sample_next_block,
	.scan_sample_next_tuple = heapam_scan_sample_next_tuple
};
```

## Sequential scan
It is good when the whole table needs to be read or when most of the table is read. This happens when the selectivity is very low.That is, the estimated size of the output is almost the same as the estimated input size. Heap supports only the sequential scan.

Here, the main fork files are read, block-by-block, tuple-by-tuple and the tuples which are not visible are filtered out. Then the tuples which don't satisfy the query are also filtered. The order of scanning the blocks is not guaranteed. This is because of an optimization allowing to join an existing scan "ring" to avoid redundant I/O. If there is an ongoing scan which is loading blocks to the buffer cache, then this query is also allowed to "join" that bulk read ring in the buffercache. The number of tuples that are expected to be read is defined by `reltuples` attribute in `pg_class`.

### I/O cost estimation
* calculated by multiplying the number of pages in a table and the cost of reading a single page **sequentially**. The cost of sequential I/O could be less as requesting a single page reads to the Operating System reading multiple pages. So when the next page is requested, there is a high chance that the OS has already read it.
* the costs used by the model are configurable
  * `seq_page_cost` (default: 1) is the cost for sequential page I/O.
  * `random_page_cost` (default: 4) is the cost for the random page I/O (used with indexes).
* this shows the effect of table bloating: larger the main fork, more would be the number of pages whether they actually contain the data or not. This is reflected by the higher cost of scan. It could also happen that we might pick an index scan and slow things down. Hence, vacuuming should be done on time.
* cpu estimates are done using `cpu_tuple_cost` parameter (default: 0.01).
* sum of cpu and I/O estimates for all the tuples is the total plan cost.
* aggregation cost is estimated based on the execution cost of a conditional operation (`cpu_operator_cost`)
* total cost of aggregate node also includes the cost of processing a row to be returned (`cpu_tuple_cost` again)

## Parallel scan
The leader process, via postmaster, spawns multiple processes to perform the scans and return results to it. Of course, there is data transfer cost besides the I/O and CPU costs. This must be taken into account while thinking of parallelizing the scans. There is also an additional `nodeGather` which acts as a synchronization point between the scanning workers.

```
# explain select count(*) from bookings;
                                         QUERY PLAN                                         
--------------------------------------------------------------------------------------------
 Finalize Aggregate  (cost=25442.58..25442.59 rows=1 width=8)
   ->  Gather  (cost=25442.36..25442.57 rows=2 width=8)
         Workers Planned: 2
         ->  Partial Aggregate  (cost=24442.36..24442.37 rows=1 width=8)
               ->  Parallel Seq Scan on bookings  (cost=0.00..22243.29 rows=879629 width=0)
(5 rows)
```
This can be verified as
```
=> with t(startup_cost) as (
   select 22243.29 + round(
      (reltuples / 2.4 * current_setting('cpu_operator_cost')::real)::numeric, 2) 
      from pg_class where relname = 'bookings')
   select
      startup_cost,
      startup_cost + round((1 * current_setting('cpu_tuple_cost')::real)::numeric, 2) as total_cost -- 1 aggregated row
   from t;
 startup_cost | total_cost 
--------------+------------
     24442.36 |   24442.37
(1 row)

```

The `ParallelSeqScan` represents the parallel heap scan. The rows here is the average number of rows scanned by each worker process (not the entire total). The cost estimation of parallel scan is similar to the sequential one: I/O costs are included in full because it is still reading from the same disk. However, the CPU cost is reduced due to parallel processing of the heap tuples. The factor is reduction is 2.4 by default. There is also `PartialAggregate` node which performs partial aggregation.

However, there is a startup cost for setting up parallel processes and transfering tuples between the worker and the master.
* `parallel_setup_cost` is the estimated cost of starting a process.
* `parallel_tuple_cost` is the estimated cost of transfering a row.

Similarly, the gathering can also be verified as follows. The costs would be
* `parallel_setup_cost` which is 25442.36 of which most is aggregation cost (24442.36)
* `paralell_tuple_cost * 2` because 2 tuples have to be transferred at a cost of `parallel_tuple_cost`.
* So `total_gather_cost = parallel_setup_cost + 2 * parallel_tuple_cost`

```
select
  24442.36 + round(current_setting('parallel_setup_cost')::numeric, 2) as setup_cost,
  24442.37 + round(current_setting('parallel_setup_cost')::numeric + 2 * current_setting('parallel_tuple_cost')::numeric,2) as total_cost;
setup_cost | total_cost
−−−−−−−−−−−−+−−−−−−−−−−−−
25442.36 | 25442.57
```

The final aggregation cost would be
* startup cost waiting for the gather to finish (`total_gather_cost`)
* aggregating two tuples corresponding to partial aggregation (`3 * cpu_operator_cost`). 3 because the master process would also be participating in the query.
* `cpu_tuple_cost` to output the tuple.

### Parallel scan control parameters
Useful for OLAP workloads
* `max_worker_processes` - maximum number of background processes running concurrently.
* `max_parallel_workers` - maximum number of processes allocated specifically for parallel processing (must be less than `max_worker_processes` as there could be other worker processes like replication, checkpointer etc)
* `max_parallel_workers_per_gatherer` - maximum number of processes for one leader.
