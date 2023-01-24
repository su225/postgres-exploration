# Locks
Heavyweight locks protect against objects like tables, live in shared memory and usually appear in `pg_locks` table. Lightweight locks are internal like spin locks, don't have safeguards like the deadlock detector trying to resolve deadlocks - they are typically used for structures like the hashtable backing the buffer cache.

They are bound by the product of `max_locks_per_transaction` and the `max_connections` parameter. That much memory is reserved in the shared memory space. So, changing this parameter requires a server restart.

Different lock types
* transactionid or virtualxid - lock on transaction ID is used to wait for a particular transaction.
* relation - relation level lock which is acquired for various SQL statements like select, update, delete, alter table etc.
* tuple - lock acquired on a tuple.
* object - lock acquired on an object that is not a relation.
* extend - a relation extension lock (to create new files in a fork?)
* page - page level lock - usually, when too many row locks are acquired, then they are promoted to a page-level lock.
* advisory - they are user defined like `select for update`.

Locks are "fair". Suppose a lock is requested such that the lock mode is compatible with that of the current executor, but there exists a lock request in the queue such that it is not compatible with the current request, then the request is still queued to ensure fairness. Otherwise, the requestor who requests in a mode which is not compatible with most modes (like `AccessExclusive`) would be starved of a chance to execute.

`pg_blocking_pids` function gives, for each PID a list of blocking PIDs who would like to acquire the locks required by it.

## Row level locks
Row level locks are not visible in `pg_locks` table and they are not kept in shared memory as it requires too much of memory. Another alternative is to escalate the row level locks to page level locks. However, this reduces the database throughput. So the only remaining option is to store them along with the tuples themselves. This is what Postgres does. The locking related hint bits are in `t_infomask` and `t_infomask2` tuple headers respectively.

There are 4 modes of row-level locks
* key shared (usually used for foreign key constraint checking)
* shared (the whole row is locked, not just the key fields)
* no key update (the key fields are not updated)
* update (exclusive lock where any field can be updated)

The `update` command selects the weakest one required. The group of transactions holding shared lock which are compatible with each other are represented by `multi_transaction_id` or `multi_xactid` which are also 32-bit integers like the Transaction ID. Unlike the heavyweight locks, the fairness is not ensured for these. For instance, if a transaction T1 is holding a shared lock and another transaction T2 is waiting for an exclusive lock and another transaction which comes after T2 asks for a shared lock then it is allowed to jump the queue. In this scenario, T2 has to wait for the completion of both T1 and T3. This could lead to lock starvation for T2. If another transaction T4 also wants a shared lock which is compatible with the current mode, then it gets ahead of T2 in the queue.

What if a transaction wants an exclusive lock, but could not get it? It requests for a "heavyweight tuple lock" on the tuple it wants to update and waits for all the transactions that are in the multixact group. Subsequent requestors also ask for the heavyweight tuple lock which is already granted to the first waiter. Once the updating transaction commits there won't be a tuple on which the lock was held. In Read Committed isolation mode another attempt is made to read, whereas in higher isolation levels the transaction is just aborted. In case multiple transactions are waiting for the exclusive lock (and hence the heavyweight tuple lock) fairness is not guaranteed among them as the queue is broken the moment tuple lock vanishes.

* `for update nowait` returns immediately if locks cannot be acquired
* `for update skip lockedd` skips the rows which are locked
* `set lock_timeout = '1s'` allows setting the lock timeout

## Deadlock
Deadlock detection and prevention is supported only for heavyweight locks. For the row level locks, once the update is finished it is released anyways. However, the waiting transactions would also be waiting on the transaction updating the actual row which is a heavyweight `transactionid` lock in the `SharedMode`. This usually causes deadlocks. Imagine the following situation
```
[txn-1] update accounts set amount = amount - 100.00 where id = 1; -- lock row with id=1
[txn-2] update accounts set amount = amount - 100.00 where id = 2; -- lock row with id=2
[txn-1] update accounts set amount = amount + 100.00 where id = 2; -- wait for txn-2's txn id
[txn-2] update accounts set amount = amount + 100.00 where id = 1; -- wait for txn-1's txn id

txn-1 waits-for txn-2
txn-2 waits-for txn-1

a cycle if formed ==> deadlock
```

The deadlock detection is run every `deadlock_timeout` parameter period. The check involves constructing the wait-for graph involving resources and the transactions holding the locks for the resources. If no deadlocks are detected, then the process goes back to sleep. If a deadlock is detected then one of the transactions is forced to terminate. In many cases, it is the process initiating the check that is interrupted. If the cycle contains an autovacuum process which is not freezing tuples, then the server terminates the autovacuum process as having lower priority.

Deadlocks should be rare and are logged. So watch out for it and also the `deadlocks` count in `pg_stat_database` table.

Deadlocks can occur when one transaction is locking rows in one order and another transaction is locking rows in another order and the row locks required by both of them overlap. This could lead to a cycle in the transactionid locks required by them as they wait for each other.

## Viewing row locks
`pgrowlocks` extension helps viewing row locks. But keep in mind that it requires reading the pages of the relation and hence it is not as cheap as reading `pg_locks` table.

## Object locks
To lock an object which is not a relation, Postgres uses locks of type `object`. Almost anything that is stored in the system catalog like tablespaces, schemas, roles, policies, enumerated data types can be locked. For instance, when a schema related information is being queried, postgres could lock to make sure that nobody messes with it until the transaction is complete. The lock levels are the same as those of the relation level locks.

## File extension locks
These are used for adding certain number of pages to the existing relation files. Since multiple backend processes should not do this, one should hold the relation extension lock, finish adding pages (usually 512 pages for table files and 1 for b-tree). Unlike other types of locks, this lock is not held until the end of the transaction, but released as soon as it is done. This is analogous to the thread-safe vector data structure where extension is transparent to the callers adding items to it. One of the threads calling `push_back` would extend the vector and the rest of them proceed to add data. This is related to the physical structure and does not have anything to do with the transaction management system.

## Page locks
Used only by the GIN Indexes which are used to speed up search in cases such as words in text documents. GIN does not index all the words, but instead adds them to the "pending" list and after a while the accumulated entries are moved into the main index structure. This works well because it is likely that many documents inserted by different transactions would have many repeated words. To avoid concurrent transfer by several different processes, the index **metapage** is locked exclusively until words are moved from the pending to the main index. This lock does not interfere with the regular index usage. **Page locks are also released immediately when the task is complete**.

## Advisory locks
They are heavyweight locks acquired manually. Postgres provides a whole bunch of functions with the prefix `pg_advisory_`. The locktype in `pg_locks` would be `advisory`. These could be used to implement custom locking in transactions. By default acquiring a lock with `pg_advisory_lock` lasts until the end of the session or a call to `pg_advisory_unlock`. There is another function called `pg_advisory_xact` which only holds the lock until the end of the transaction like other built-in heavyweight lock types.

## Predicate locks and serializable snapshot isolation
Predicate locks actually don't lock anything. They are used to track data dependencies among different transactions. These exist to prevent write skew and read-only snapshot isolation transaction anomaly. These two arise from certain types of dependency graphs
* **RW-dependency**: The first transaction T1 reads a row that is updated by the second transaction T2. `T1 --(RW)--> T2`
* **WR-dependency**: The first transaction T1 modifies a row that is later read by the second transaction T2. `T1 --(WR)--> T2`

**WR-dependency** can be identified by locking. That's what row locks are for. But **RW dependencies** need to be tracked through predicate locks. Postgres checks for circular RW dependencies among transactions and conservatively aborts to enforce serializability.

* all predicate locks are always acquired in `SIReadLock` mode
* sequential scan predicate-locks the whole table (bad and coarse grained leading to more transaction conflicts)
* index scan only locks the leaf-page and the tuple (much better and fine grained)
* they are for **tracking dependencies between transactions**.
* they are held longer than the transaction that acquired it.
* predicate locks use their own pool configured by `max_pred_locks_per_transaction`.
* lock escalation is applied in case many tuples acquire locks (to page locks). It is configured by `max_pred_locks_per_page` for escalating from tuples to page. The page lock can be escalated to relation-level lock and is configured by `max_pred_locks_per_relation` configuration parameter.
* `$PGDATA/pg_serial` contain information on the committed serializable transactions (maybe this is where `SIReadLock` information after commit is tracked?)

Why are they held longer than the locking transaction? Suppose T1 started and read some rows, then T2 started read some overlapping rows and wrote something which is predicate-locked by T1. Now there is `T1 --(RW)--> T2`. If T1 tries to write to the rows that was read by T2 earlier, then there would be `T2 --(RW)--> T1`. This leads to a circular dependency violating serial order and hence T1 needs to be aborted as T2 has already committed. Suppose, if the predicate lock acquired by T2 was released when T2 committed, then `T2 --(RW)--> T1` dependency could **NOT** have been detected because there needs to be some record that T2 which wrote something that T1 had read before (creating `T1 --(RW)--> T2`) had also read some rows before that T1 is reading now to create `T2 --(RW)--> T1` dependency.

To give the doctors' oncall example: Let us consider transaction `T-Alice` and `T-Bob` on table `oncall`.
1. `T-Alice` reads `oncall` table and hence acquires `SIReadLock` on `oncall` table.
2. `T-Bob` also reads `oncall` table and also gets `SIReadLock` on `oncall` table.
3. `T-Bob` updates the oncall schedule marking himself unavailable. Because of `SIReadLock`, an RW dependency `T-Alice --(RW)--> T-Bob` is created by this step. Then `T-Bob` commits. But the `SIReadLock` acquired by `T-Bob` is not yet released.
4. `T-Alice` tries to update the oncall schedule and runs into conflict because it creates `T-Bob --(RW)--> T-Alice` which creates a circular dependency with the earlier update by `T-Bob`. Hence the transaction aborts. In subsequent retries, `T-Alice` sees the update performed by `T-Bob`. Here, `SIReadLock` held by `T-Bob` even after committing gave a clue that `T-Bob` had also read the `oncall` table and the RW dependency gave a clue that `T-Bob` had updated it.

When is an `SIReadLock` released though? It is associated with a transaction. When a transaction starts, it takes a snapshot containing its `xid` along with the `xid` of all the running transactions at that time. Transaction that come after the acquiring transaction commit clearly come after it in serialization order, but we cannot say the same about the concurrent transactions. Maybe, it is possible to find some order provided they updated some unrelated tuples or tables which don't conflict. Or maybe they conflict as shown in the example above. Hence, the predicate lock is released only after all the transactions concurrent to the transaction that acquired it have ended with either commit or rollback. It makes sense because we need to track dependencies carefully only among these.

### Phantom read
Within the same transaction, same query produces two different sets of rows. This could happen when rows satisfying query conditions are inserted in between the two queries within the same transaction. This could be observed in read-committed isolation level, but not in repeatable-read and serializable isolation levels. The problem occurs because we cannot lock the rows which don't exist yet. We have to lock conditions and that's what predicate locks are for - in practice, they are conservative approximations.

### Write skew
Two transactions T1 and T2 read an overlapping data set, make disjoint updates by computing something based on the reads without knowing about the other ones updates. These usually result in constraint violation where evaluating a constraint involves reading multiple rows. Suppose, there is a hospital management system where there is an oncall schedule telling that at least one doctor must be oncall. Suppose Dr.Alice and Dr.Bob want to take a leave on some day where both of them are listed as oncall. Both of them read the schedule and see that the other is available and update their status as unavailable. Here, both rows related to Dr.Alice and Dr.Bob are read, but Dr.Alice's transaction updates only Alice's row and same with the Bob and hence they are disjoint. However, the constraint that at least one doctor must be oncall is violated because both of them marked as unavailable. This is prevented only with **serializable** isolation level.

Another example is the calendar app and the meeting room booking system where two clients try to book the overlapping times. Of course, this depends on the design of the database tables and schemas. If they result in disjoint updates, then it could happen.

### Read-only transaction anomaly
Suppose savings and checking account balanaces start with 0 and the bank imposes a $1 overdraft fee when the sum of checking and savings account balances goes below 0.
Txn1: Add $20 to savings
Txn2: Subtract $10 from checking. If doing so causes (checking+savings) to go below 0, then additionally subtract $1 overdrafting fee
Txn3: Read balances (checking,savings)

It is possible for Txn3 to read (checking:0, savings:20), but still end up with total balance of 9. This does not correspond to any serially consistent snapshot of the database. That is, had the transactions executed one by one this would not have happened. 

With serial execution, the only possibilites would be
1. Txn3 -> Txn1 -> Txn2 ===> (0, 0) 0
2. Txn3 -> Txn2 -> Txn1 ===> (0, 0) 0
3. Txn1 -> Txn3 -> Txn2 ===> (0, 20) 20
4. Txn2 -> Txn3 -> Txn1 ===> (-11, 0) -11
5. Txn1 -> Txn2 -> Txn3 ===> (-10, 20) 10
6. Txn2 -> Txn1 -> Txn3 ===> (-11, 20) 9

However, under this anomaly it is possible to observe (0, 20) when the resulting sum is 9. This is because of concurrency. Consider the following execution sequence.
* txn1: read(savings) = 0
* txn1: write(savings) = 20
* txn2: read(savings) = 0
* txn2: read(checking) = 0
* txn1: commit
* txn3: read(savings) = 20
* txn3: read(checking) = 0
* txn2: write(checking) = -11
* txn2: commit

Reading
* [Read-only transaction anomaly under snapshot isolation](http://www.cs.umb.edu/~poneil/ROAnom.pdf) - originally referenced from [this blog post](https://johann.schleier-smith.com/blog/2016/01/06/analyzing-a-read-only-transaction-anomaly-under-snapshot-isolation.html)