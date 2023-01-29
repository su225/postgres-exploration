# Statistics
Keeping statistics for various attributes in a table is very important to come up with accurate cost estimations and better query plans. The problem is that the distribution could change over time and statistics, if stale, could lead to very bad plans.

* relation level statistics are stored in `pg_class`
  * `reltuples` is the number of tuples
  * `relpages` is the size of the relation in pages
  * `relallvisible` is the number of pages tagged as all visible
* basic statistics could be calculated during other operations like `vacuum full`, `create index`
* in large tables, statistics collection does not include all the rows.
* rows are sampled from random pages and their number is set by `300 * default_statistics_target` number of random pages.
* new tables are not analyzed and when not analyzed, the planner assumes that a table consists of 10 pages (80K).
* planner also takes table file size into account to come up with an accurate estimation of the number of tuples in case `reltuples` is not accurate.

## NULL values
* `not in` clauses might behave unexpectedly.
* `nulls first` and `nulls last` help ordering nulls with regular values.
* if predicate is `is null` or `is not null`, the planner uses the null fraction recorded in the `pg_statistic` table. It is the `stanullfrac` column.

Finding null fraction for a column
```sql
select 
  a.attname,
  s.stanullfrac
from pg_statistic s 
  inner join pg_attribute a 
  on s.staattnum = a.attnum 
    and s.starelid = a.attrelid
where s.starelid = 'flights_copy'::regclass::oid 
and not a.attnotnull;
```

## Distinct values
The `n_distinct` in `pg_stats` view gives the number of unique values. If the value is negative then the absolute value gives the average number of times each value occurs. This is OK if the distribution is uniform. But a skewed distribution leads to incorrect estimations and bad query plans. For instance, take pareto distribution of values. If a value which occurs 90+% of the time is queried and the planner picks the index access method instead of the sequential scan. This leads to very inefficient querying. Same with the other way around where a rarely occuring value is queried and sequential scan is used.

## MCV, MCF and Histogram
To mitigate against this, the most common value (MCV) statistics is also maintained along with most common frequencies (MCF). Plus, the bounds of the histogram representing the distribution are also maintained (how are these bounds decided though?). To estimate the selectivity of the `column = value` clause it is enough to find the frequency of `value` from the `most_common_freqs` array. The `most_common_values` is used to estimate the selectivity of the inequalities like `<` condition and sum up the frequencies present in `most_common_freqs`.

MCV stores actual values. So the size of the `pg_statistics` has to be controlled. Hence, values larger than 1K are excluded from analysis and statistics. Large values are likely to be unique and hence they don't make it to the most common values anyways.

## Correlation
Correlation between the physical order of data and the logical order defined by comparison operations. It will be close to 1 if the values are stored in strictly ascending order physically as well. For descending order, it will be close to -1. Correlation is used for cost estimation of index scans. On high correlation, we have more opportunities for serial I/O within a table file.

## Expression statistics
`CREATE STATISTICS` can be used to create statistics on expressions. But to make use of that, the exact same expression has to be used in the where clause for matching.

## Multivariate statistics

### Correlated columns
It is `create statistics` again. Multivariate stats are important especially when there are correlated columns. As selectivity for an AND condition is computed as the product, the number of rows could be vastly underestimated which could lead to bad plans like selecting index scan whereas sequential scan would have been quicker. Multivariate statistics have to be created manually with `create statistics`. One such example is as follows
```sql
CREATE STATISTICS flights_dep(dependencies)
ON flight_no, departure_airport FROM flights;
```
Then, querying for the collected statistics, we get
```
=> SELECT dependencies
FROM pg_stats_ext WHERE statistics_name = 'flights_dep';
dependencies
−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−
{"2 => 5": 1.000000, "5 => 2": 0.010200}
(1 row)
```
Here 2 is the `flight_no` column and 5 is the `departure_airport` column. The value for `2 => 5` indicates that the values in column 5 are completely dependent on the value of column 2. That is, `departure_airport` is completely dependent on the `flight_no`. However, the `flight_no` is far less dependent on the `departure_airport`. Given the departure_airport, we can say what are the possible flight numbers that leave it. However, given the flight number it is not possible to say with certainty what the departure airport would be.

### Improving `group by` clause by multivariate distinct values
For instance, the maximum number of arrival and departure pairs is proportional to the square of the number of airports. However, in reality, it is much lesser as not all pairs are correlated. This could lead to overestimation and choosing wrong access method. Again, `create statistics` can be used for this purpose.
```sql
CREATE STATISTICS flights_nd(ndistinct)
ON departure_airport, arrival_airport FROM flights;
```

### Handling non-uniform distribution with multivariate MCV
```sql
CREATE STATISTICS flights_mcv(mcv)
ON departure_airport, aircraft_code FROM flights;
```
