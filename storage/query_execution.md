# Query planning and execution
Usual compiler stuffs like lexing, parsing and semantic analysis occurs. Then logical planning with some query rewrites, optimizations like predicate and projection push-down is performed, physical planning (selecting access methods), selecting join order etc.

Each query sent to Postgres has to undergo these steps
* parsing
* transformation
* planning
* execution

## Prepared statements and avoiding parsing overhead
However, the extended query protocol allows preparing statements in advance so that the overhead of parsing can be avoided. This is the concept of **prepared statements**. So prepared statements don't avoid the planning overhead. A prepared query can also be parameterized as follows
```sql
prepare plane(text) as
select * from aircrafts where aircraft_code = $1;
```
The prepared statements can be viewed from `pg_prepared_statements`. They also contain statistics on generic and custom plan counts.

On keeping query plans:
* when there are no parameters, then the "generic plan" can be cached along with the parse tree.
* when there are parameters, then "custom plans" are generated for upto 5 queries which are based on custom values. Then, it switches to using generic plans which is cached. This works well when the data distribution does not change over time. However, the `plan_cache_mode` switch can be set to `force_custom_plan` so that the query is planned every time. This works well when different parts of the distribution are better with different access modes (for instance, if a predicate is satisfied by almost all rows in a table, then sequential scan makes more sense than index).

## Getting results and cursor
```
=> begin;
=> declare cur cursor for
      select * from aircrafts order by aircraft_code;
=> fetch 3 from cur;
=> fetch 2 from cur;
```
Named cursors can be used to fetch few items at a time instead of all the items. However, the downside is that it involves several roundtrips. Also, depending on the application, it may not make sense to keep the cursor open when there is interactivity. This is because the backend process, the cursor and the state associated with it on the server is kept alive and this consumes database and OS resources.

## Generating possible plans
The planner works by scanning each individual relation used in the query. The possible plans are determined by the available indices. For instance, if a table does not have an index, then the only possible way is "sequential scan". If the access is by primary key, then an index can be used. If the column or a set of columns specified in the `where` clause have an index defined on them, then using "index access method" is possible. Generating all possible plans are prohibitively expensive in terms of time and memory. Keep in mind that this affects query latency badly. So a good enough plan generated quickly is much better over the most optimal plan taking a long time for generation.

SQL is declarative and hence planning is needed. Just like how developers design appropriate data structures and use them depending on the operations they are optimized for, planners also do the same. They have a cost model for various operations, collect statistics as they execute queries and generate plans based on them. If the statistics and the cost model are wrong, then don't be surprised by terrible plans and the resulting query latency.

Planning involves picking access methods, rewriting queries like pushing down predicates and projection as close as possible to the access method so that the tuples bubbling up the execution plan tree consume less memory and temporary disk space. This is especially important for joins which should scan through the data. The next would be picking the join order and the join algorithms
* nested loop join (good old O(N*M) algorithm)
* sorted-merge join (merge sort O((N+M) log (N+M)) algorithm)
* hash join (build hash table of the smaller side and scan through the larger side)

Then execution involves deciding if the plan should be compiled in-advance or just-in-time or just use the interpreter or use vectorized/SIMD instructions to speed up certain operations, the level of parallelism to use etc. How the plan should be executed?
* iterator model where the data is pulled up on demand by executing higher-level operator (top-to-bottom)
* push model where the results are computed bottom-up and pushed up.

## Join order selection
* common table expressions and the main query can be optimized separately; to guarantee the behavior specify `materialized` clause
* subqueries run within non-SQL functions are always optimized separately. SQL subqueries are sometimes inlined
* set `join_collapse_limit` and use explicit `join` clauses.
* set `from_collapse_limit` is like `join_collapse_limit`, but on subqueries.

Planning algorithms
* dynamic programming for small number of tables - slow, but more accurate. Time complexity is exponential in the number of data sets that need to be joined.
* genetic optimizer after some threshold set by enabling `geqo`(GEnetic Query Optimizer) and `geqo_thresold`. However, unlike the dynamic programming, the plan generated is not guaranteed to be optimal.

### Join order collapsing
Suppose the query is
```sql
select * from a, b, c, d, e;
```
Then the join here is implicit and the parse tree is flattened such that all the tables are at the same level. This means that during execution, they all are joined together.
```
(from-expr (a b c d e))
```
However, the query with an explicit join clause has a different parse tree and depending on `join_collapse_limit` setting, a different execution
```sql
select * from a, b join c, d, e;
-- (from-expr (a (join-expr b c) d e))
```
If the `join_collapse_limit` parameter is 5, then if the number of expressions to join is less than or equal to 5, then they are flattened. If it is more than that, then the explicit join ordering specified is maintained. For instance, the above query when `join_collapsed` would be
```
(from-expr a b c d e)
```
Setting `join_collapse_limit` to 1 would always retain the join ordering explicitly mentioned in the query. A special case is the `full outer join` which is never collapsed.

## Example query plan
```
                                                   QUERY PLAN                                                   
----------------------------------------------------------------------------------------------------------------
 Sort  (cost=22.34..22.35 rows=1 width=128)
   Sort Key: c.relname
   ->  Nested Loop Left Join  (cost=0.00..22.33 rows=1 width=128)
         Join Filter: (n.oid = c.relnamespace)
         ->  Seq Scan on pg_class c  (cost=0.00..21.24 rows=1 width=72)
               Filter: ((relkind = ANY ('{r,p}'::"char"[])) AND (pg_get_userbyid(relowner) = 'postgres'::name))
         ->  Seq Scan on pg_namespace n  (cost=0.00..1.04 rows=4 width=68)
(7 rows)

```
`cost=x..y`: Here `x` is the cost to prepare for executing the node (gathering prerequisite data) and `y` is the total expense for actually fetching the result from the query plan node. Although inaccurate, `x` is sometimes seen as the cost to fetch the first row from the operator. In the above example, it makes sense for sort operator because it needs to have all the rows before it can start its operation - that explains high cost. However, the start cost of nested loop join is also 0 even though there is an "exchange" operator which prevents join from starting unless tuples from both tables are accessed. It might make sense as nested loop join does not require any joining, but just reading tuples from the table.

The selected plan depends on whether the cursor is used or not. When it is not used, then it is straightforward - the database assumes that all rows are required and the cost is to fetch all of them. If the query is executed with a cursor then the selected plan must optimize retrieval of only `cursor_tuple_fraction` of all rows. Postgres chooses the smallest plan with formula
```
startup_cost + cursor_tuple_fraction*(total_cost - startup_cost)
```
When `cursor_tuple_fraction` is 1, it means all rows need to be retrieved and the cost is the `total_cost` (the `y` or the second number in the costs representation). `startup_cost` is paid upfront irrespective of whether cursor is used or not. The remaining cost is paid up by fraction when cursor is used and that fraction is the `cursor_tuple_fraction`.

For instance, in the above "nested loop join", the cost formula would be `cursor_tuple_fraction * total_cost`. This makes sense as this sounds similar to yielding execution after filling up a batch. The cost paid is not the full cost of executing which includes the materialization. However, for sorting the `startup_cost` is high because all the tuples need to be fetched and we are executing a sequential scan. Perhaps, it can be lowered by using a btree index on the column specified in `order by` clause as the scanning of tuples can be ordered on access. This lowers startup cost drastically.

## Factors affecting query plans
* node type representing access methods and operations (obvious one)
* **cardinality**: estimation of the amount of input data to be scanned
* **selectivity**: estimation of the amount of output data or how much would be filtered out.
* calculations are based on the accuracy of collected statistics in `pg_statistic` (per column) which collects stats for the frequent operations, histogram representing value distributions, null fraction, unique value fraction etc.

## Cardinality and selectivity estimation
It is calculated bottom up: assess cardinality of each child node and estimate the number of input tuples returned by them (which in turn depends on their selectivity and cardinality - a.k.a their output). Then estimate the selectivity of the node to calculate the fraction of the inputs that would remain in the output.

For the access methods like heap, the cardinality or the number of tuples read would be all the rows. For the index, it would be the number of index pages multiplied by the number of keys per page and so on. The selectivity would be nil for heap access method because it is a sequential scan. Hence, the factor would be `1` (not selective at all). Similarly, for indexes it would be somewhere between 0 and 1 because something like a b-tree cuts down the search space (that's the whole point of having an index).

Estimating selectivity of filter conditions is hard. It depends on the statistics saved for each column. Typically, for the logical operators it is calculated as follows
```
selectivity(X AND Y) = selectivity(X) * selectivity(Y)
selectivity(X OR Y) = 1 - (1-selectivity(X))(1-selectivity(Y))
```
Intuitively, AND makes a query far more selective (the factor goes down) and the OR makes it far less selective (factor goes up). However, the above formulas are valid only if X and Y are not correlated and are independent. **Note that the estimation errors in the lower parts of the tree bubble up and could multiply**.

The cardinality and the selectivity of a join condition is estimated based on those from the child nodes. The selectivity of the join depends on the join condition. The number of combinations to deal with is the product of all the tuples from the children. This is assuming the join condition is not present and is just a cartesian product. Then, the selectivity of the join condition is applied to compute the output. To make things harder, the planner has no statistics on the join itself, but just the tables being joined. The deeper the tree, more would be estimation error and more chances of the plan going off.

The selectivity of the sort or the `order by` clause is 1 because it does not filter out any tuples.

## Query execution
Postgres follows the pull model as opposed to push or the vectorized or the pipeline execution model. Some nodes need to store the results before they can execute. For instance, `order by` should store all the tuples before it can sort them. It means that query execution requires memory for intermediate operands besides tracking the query execution status.
* the backend `executor` opens a `portal` in the backend's memory that keeps track of the state of the query being executed.
* `work_mem` chunk of memory is allocated for query execution nodes like `order by` which require memory to store intermediate results. Same with large joins (for instance, `hashtable` in hash joins and the sorted datasets in sort-merge join. Hence, the side with smaller data set is chosen for the hashtable in hash-joins. In case of sorted merge join, the whole data set has to be sorted and hence it takes more memory and possibly spilling more data to disk ==> more I/O). If that is not enough, then the remaining data is spilled over to the disk into temporary files.

There is no memory limit for an individual query. However, spilling a lot of data to disk could incur I/O costs depending on the backing storage. This could also introduce quite a lot of latency due to swapping, disk I/O.
