# Buffercache
In-memory buffer cache: hashtable
* vacuuming reads lots of pages across fork types and loads it into the cache.
* vacuum cannot mess around with pinned pages.
* header lock is not needed to access pinned pages because the tag is unlikely to be changed.
* header status flags are managed by atomic operations and hence don't need a lock.
* `BufferAlloc` actually allocates buffer cache slot.

## Picking the spot
* available buffers are in a free-list
* a buffer is obtained when required as part of read (buffer allocation)
* a buffer is returned to the list only when it is not needed - for instance truncate or drop table commands or if the buffer is freed by vacuuming process.
* once there are no more buffers available, then eviction algorithm is run.
* eviction is performed by the clock sweep algorithm.

### Clock-sweep eviction algorithm
* simulates the least-frequently and least-recently used algorithm by looking at **usage count** of the buffer-page.
  * page used more frequently in the past would have higher usage count.
  * page used way back in the past has high likelihood of having its usage count reduced by sweep rounds.
  * if all buffers have non-zero usage counts then another sweeping round has to be performed (hence usage count is limited to 5)
* goes around the allocated buffers and reduces usage count by 1 in each round (max usage count is 5).
* the first **unpinned** page with usage count of 0 would be evicted.
* the newly loaded buffer is **pinned** and usage is set to 1.

## Eviction strategies for bulk scans
* **bulk read**: 256KB is allocated, the buffer in the ring is not written back to disk if it is dirtied by some other process. Instead, it is detached and new buffer is added to the ring for future use. It is used not only by sequential scans, but also by `UPDATE` and `DELETE` statements. It seems like this is based on the assumption that there will not be frequent bulk update and delete operations. (what about data warehousing applications a.k.a OLAP where the performance of such things indeed matter?). This is used when the table size exceeds 1/4th of the buffer cache size. This ring is shared between the processes scanning the same table (hence it is not guaranteed that the scanned data would be in any order).

* **bulk write**: By default, 16MB is allocated and it never crosses 1/8th of the buffer cache size. It is for operations like `create table with select`, `create materialized views`, `alter table` where large scale table writing/rewriting needs to be performed. The allocated ring size is big so that there would be some time to flush dirtied buffers to disk before reusing them.

* **vacuuming**: It is full table scan with buffer allocation of 256KB without taking visibility map into account. On vacuuming, visibility map and free space maps could be re-written as space is freed and tuples are frozen.

## File references
* backend/storage/buffer/bufmgr.c - buffer manager
* src/include/storage/buf_internals.h - buffer internals with buffer header, descriptors
* backend/storage/buffer/freelist.c - free-list of buffers