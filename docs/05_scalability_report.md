# Scalability report (Phase 5): seed data vs official large data

> **Data:** the numbers in the "Large" column come from the official `large_data.zip` released by the faculty (2,401,264 properties, 2,000,000 enquiries, 800,000 users, 1,400,000 shortlists, 699,415 site visits: about 20x the seed). It was loaded with `benchmarks/run_large.sh` (our `sql/01_schema.sql` and `sql/02_load_data.sql`, folder name changed only), indexed with `sql/05_indexes.sql`, and the **optimized** workload `sql/06_optimized_queries.sql` was run 3 times per query. Raw plans and `summary.csv` are in `benchmarks/results/large/`. The column "Rehearsal" is an earlier run on a copy of the data that we generated ourselves before the official files were out (`benchmarks/results/large_rehearsal/`); it is kept only to show that the two runs agree.
> All timings come from a cloud container (2 vCPU / 8 GB), not a team laptop. **TEAM TO CHECK:** re-run on your laptop if the course needs your machine, and write its specs here.

## 1. Summary

- The same indexes (`sql/05_indexes.sql`) and optimized queries (`sql/06_optimized_queries.sql`) as on the seed were used on the official large data (about 2.4M properties, 2M enquiries). Loading took 2 min 47 s and the indexes 23 s. The integrity checks I1 to I7 of the load script all return 0 violations on the large data (`benchmarks/results/large/integrity_checks.txt`).
- Sum of the 30 averages: **451.2 ms on seed, 9755.5 ms on the large data** (21.6x for 20x the data).
- **24 of 30 targets met. 6 missed and explained below: R01, R02, R09, R12, R17, W04.**
- Two problems showed up only at scale and were fixed: the I2 integrity check in the load script and the `IN (subquery)` form of R25 (both ran for over 10 minutes on our 20x rehearsal copy). With the fixes, I2 finishes inside the load and R25 takes about 2.8 s on the official data.
- Architecture for 100x: monthly RANGE partitioning of `properties`, sharding by city, read replicas for search, and autovacuum tuning (section 6).

## 2. Results: seed (optimized) vs official large data

Averages of 3 runs of `EXPLAIN (ANALYZE, BUFFERS)` execution time, from `benchmarks/results/optimized/summary.csv` and `benchmarks/results/large/summary.csv`. Raw plans are next to those files.

| Query | Target class | Target (ms) | Seed (ms) | Large (ms) | Growth | Rehearsal (ms) | Target met |
|---|---|---|---|---|---|---|---|
| R01 | real-time | <5 | 0.537 | 7.601 | 14.2x | 7.6 | **NO** (see section 4) |
| R02 | real-time | <5 | 0.987 | 16.246 | 16.5x | 16.1 | **NO** (see section 4) |
| R03 | real-time | <5 | 0.242 | 0.219 | 0.9x | 0.2 | yes |
| R04 | report | <5000 | 0.360 | 4.491 | 12.5x | 3.0 | yes |
| R05 | real-time | <5 | 3.396 | 2.599 | 0.8x | 2.1 | yes |
| R06 | real-time | <5 | 0.722 | 1.412 | 2.0x | 0.5 | yes |
| R07 | real-time | <5 | 0.199 | 0.330 | 1.7x | 0.2 | yes |
| R08 | interactive | <250 | 3.583 | 54.909 | 15.3x | 42.8 | yes |
| R09 | interactive | <250 | 7.131 | 261.818 | 36.7x | 221.5 | **NO** (see section 4) |
| R10 | real-time | <5 | 0.179 | 0.741 | 4.1x | 0.1 | yes |
| R11 | real-time | <5 | 0.461 | 0.445 | 1.0x | 0.3 | yes |
| R12 | interactive | <250 | 13.547 | 285.910 | 21.1x | 241.5 | **NO** (see section 4) |
| R13 | interactive | <250 | 3.141 | 75.357 | 24.0x | 66.1 | yes |
| R14 | report | <5000 | 21.818 | 377.567 | 17.3x | 272.3 | yes |
| R15 | report | <5000 | 4.702 | 124.363 | 26.4x | 85.1 | yes |
| R16 | interactive | <250 | 0.593 | 20.711 | 34.9x | 9.1 | yes |
| R17 | interactive | <250 | 50.546 | 794.818 | 15.7x | 634.8 | **NO** (see section 4) |
| R18 | report | <5000 | 29.056 | 1068.209 | 36.8x | 878.7 | yes |
| R19 | report | <5000 | 20.844 | 355.523 | 17.1x | 271.9 | yes |
| R20 | report | <5000 | 1.925 | 51.305 | 26.7x | 30.6 | yes |
| R21 | report | <5000 | 24.435 | 635.921 | 26.0x | 631.6 | yes |
| R22 | interactive | <250 | 0.063 | 0.085 | 1.3x | 0.1 | yes |
| R23 | real-time | <5 | 0.058 | 0.061 | 1.1x | 0.1 | yes |
| R24 | interactive | <250 | 0.291 | 5.064 | 17.4x | 4.6 | yes |
| R25 | report | <5000 | 169.923 | 2755.373 | 16.2x | 2282.1 | yes |
| W01 | real-time | <5 | 1.118 | 1.336 | 1.2x | 1.8 | yes |
| W02 | real-time | <5 | 0.579 | 0.595 | 1.0x | 0.6 | yes |
| W03 | real-time | <5 | 1.539 | 1.183 | 0.8x | 1.2 | yes |
| W04 | batch | <1000 | 88.624 | 2850.662 | 32.2x | 2125.6 | **NO** (see section 4) |
| W05 | real-time | <5 | 0.623 | 0.617 | 1.0x | 0.5 | yes |

## 3. Growth analysis (data grew about 20x)

- **Roughly flat (under 2x): 10 queries.** R03 (0.9x), R05 (0.8x), R07 (1.7x), R11 (1.0x), R22 (1.3x), R23 (1.1x), W01 (1.2x), W02 (1.0x), W03 (0.8x), W05 (1.0x). These are primary-key or narrow index lookups whose cost depends on the number of rows returned, not on table size. Several got slightly faster only because of run-to-run noise at sub-millisecond level.
- **Between 2x and 20x ("about linear or better"): 11 queries.** R01 (14.2x), R02 (16.5x), R04 (12.5x), R06 (2.0x), R08 (15.3x), R10 (4.1x), R14 (17.3x), R17 (15.7x), R19 (17.1x), R24 (17.4x), R25 (16.2x). Their work is proportional to rows returned or aggregated, which grew 20x, and indexes keep the growth at or below that.
- **More than 20x (super-linear): 9 queries.** R09 (36.7x), R12 (21.1x), R13 (24.0x), R15 (26.4x), R16 (34.9x), R18 (36.8x), R20 (26.7x), R21 (26.0x), W04 (32.2x). Typical causes seen in the plans: joins and aggregations over large tables whose hash tables or sorts no longer fit in cache (R09, R12, R21), whole-table grouping (R18) and a bulk update that scans the whole table (W04). R16 grew most in ratio but is only 20.7 ms in total. These are the ones to watch at 100x.
- Reading across the three groups: the indexes in `sql/05_indexes.sql` scale well for lookups. The cost at scale sits in whole-table aggregates and the single bulk write, which no index can fix; that is what partitioning and pre-aggregation address in section 6.

## 4. What broke at scale, and what we did

### 4.1 I2 integrity check in `sql/02_load_data.sql` (found only at 20x, on our rehearsal copy)
The original check compared each property's price to its latest `price_changes` row with a correlated subquery. On 20x data it ran for more than 11 minutes and was killed. Rewritten with `DISTINCT ON (property_id) ... ORDER BY property_id, changed_at DESC` joined once; it finishes in seconds. Same violations count (0) on seed.

### 4.2 R25 `IN (SELECT property_id, user_id FROM enquiries)` (found only at 20x, on our rehearsal copy)
On seed it took ~170 ms; on our 20x rehearsal copy the subquery result no longer fit in `work_mem`, PostgreSQL stopped using a hashed SubPlan, and the query was killed after 10 min 34 s. Replaced by a LEFT JOIN against `SELECT DISTINCT property_id, user_id FROM enquiries` (`count(e.property_id)` counts the matches). Result is identical (checked in `sql/07_verify_results.sql`); time on the official data is **2755 ms** (target 5000 ms). Raw output of the killed run was not saved, see `benchmarks/results/large_rehearsal/experiments/NOT_SAVED_NOTES.md`.

### 4.3 The targets we missed

- **R01: 7.6 ms against <5 ms** (real-time). Heap fetches: `status`/`furnishing` are not in any index (a status index makes every status UPDATE non-HOT, see W04). 0.5 ms became 7.6 ms because the matching rows grew 20x. Warm re-runs gave about 4.8 ms (median 5.4 ms); first run is cold.
- **R02: 16.2 ms against <5 ms** (real-time). Same cause as R01: about 10 locality probes, each returning 20x more rows to check against `status`.
- **R09: 261.8 ms against <250 ms** (interactive). Joins 1,145 projects that have all three amenities to their active properties: 1,145 bitmap probes of `idx_prop_project`, 63,136 heap blocks, 19,373 rows sorted for `LIMIT 50` (plan in `benchmarks/results/large/R09.txt`). It grew about 37x for 20x the data, and it is only about 5% over the target (262 ms against 250); our rehearsal copy gave 221 ms, so this one sits on the border and depends on the data. `status` is checked on the heap for the same reason as R01.
- **R12: 285.9 ms against <250 ms** (interactive). Returns about 75,000 enquiries of a 23-day window that have no site visit, sorted by date. The sort spills to disk (`external merge`, 2.5 MB) and the anti join has to hash all 699,415 site visits (plan in `benchmarks/results/large/R12.txt`). The result is large, so even a perfect plan has to produce and sort 75k rows; our rehearsal copy gave 242 ms, just under the target, the official data is 14% over.
- **R17: 794.8 ms against <250 ms** (interactive). Set difference over most of `properties` and `enquiries` (all active listings older than 90 days with no enquiry). Per problem statement P4 it is an hourly job, not an interactive page, so we keep it as a report-class query; nothing we tried (status-partial indexes, CLUSTER) helped it enough to justify the W04 cost.
- **W04: 2850.7 ms against <1000 ms** (batch). The statement itself updates about 288,000 rows (287,639 in the last run; 20x of ~14,400), and it first has to scan all 2.4M properties (800 ms of its 2.45 s in the last run). About 97% of the updates are HOT (measured on the rehearsal copy), so it is about 8 to 10 us per row. Meeting 1000 ms would need indexing `status`, which was measured to make W04 slower (see 'What broke at scale'). In production this batch would run in chunks by locality or by partition, not as one statement.

### 4.4 Options measured on our 20x rehearsal copy and rejected (before the official data was out)
| Option | What we measured | Why rejected |
|---|---|---|
| `CLUSTER properties USING idx_prop_search` | R01 2.1 ms, R02 2.8 ms, R09 98 ms (all better) but W04 **6.6 s** (3.5 to 3.9 s even with fillfactor 70) | Rewrites the table on every bulk status change and has to be re-run as data drifts; W04 gets 3x worse. Raw output not saved. |
| Partial indexes on `status = 'ACTIVE'` | R01 3.3 ms, R02 8.7 ms (better) but W04 **18.3 s** | Every status change moves a row in or out of the index, so updates cannot be HOT. Files: `benchmarks/results/large_rehearsal/experiments/status_partial_indexes/`. |
| Index `status` on seed (design A) | W04 slower than without it (table in `docs/04_optimization_report.md`) | Same rule: no index mentions `status`. |

Choosing between R01/R02 at 7.6 and 16 ms and W04 at 2.1 s versus 18 s is a trade-off between reads and writes; we chose to protect the write path and document the misses.

## 5. Storage

| | Seed | Official large data |
|---|---|---|
| Whole database | 97 MB | 1768 MB |
| `properties` table | 22 MB | 439 MB |
| `properties` indexes (all) | 32 MB | 638 MB |
| `enquiries` table / indexes | 6.9 MB / 8.4 MB | 135 MB / 163 MB |
| Our 8 new indexes together | 37 MB | 733 MB (sum of the 8 sizes in `benchmarks/results/large/db_sizes.txt`) |

Indexes cost about 1.5x the table size on `properties`. The biggest single index, `idx_prop_search` (INCLUDE columns, 193 MB on the large data), is also the one that pays off most (R01, R02, R04, R15).

## 6. Design for 100x

Seed is ~120k properties, so 100x of the seed is ~12M properties, and 5x the official large data. Everything here is a design backed by the measurements above, not something we ran at 100x.

### 6.1 Partitioning (`sql/08_partitioning.sql`)
- **Table and key:** `properties`, RANGE on `posted_at`, one partition per month (19 partitions plus a DEFAULT partition on the seed). Time is the dimension along which data ages (R20, R22, R17, W04), and old months can be detached and archived without a large DELETE.
- **Pruning demonstrated** (`benchmarks/results/optimized/partitioning_seed.txt`): R20 for one month scans only `properties_2026_06` (1 of 20). R22 keyset pages use a Merge Append over the per-partition `posted_at` indexes.
- **No pruning when the query has no time filter.** R01 and R03 probe every partition. Measured on the seed: R03 goes from 0.04 to 0.07 ms execution to 0.35 to 1.3 ms, and planning time from about 0.4 ms to about 7 ms. So partitioning would make the real-time lookups worse unless planning is cached (prepared statements) or the application passes `posted_at` too.
- **Primary-key rule:** a PK on a partitioned table must include the partition key, so the key becomes `(property_id, posted_at)`. Consequences: `property_id` alone is not unique-enforced, so `enquiries`, `site_visits`, `shortlists` and `price_changes` can no longer have a foreign key to `properties(property_id)`. We would keep those as unenforced references and run a periodic orphan check, or carry `posted_at` into the child tables.
- **Honest limit:** we measured pruning and the point-lookup cost on the seed only. We did not measure W04 or the other queries on a partitioned 20x table, so we do not claim a speed-up number. A zero-cost win we do expect is that W04 and R17 touch only partitions older than 90 to 120 days and autovacuum can skip cold partitions.

### 6.2 Sharding by city
- **Key:** `city_id`. Search is always city-scoped (every search query starts from a locality), so a query touches one shard.
- **Balance** (official large data, `housing.properties` per city): Mumbai 241,522; Pune 240,630; Ahmedabad 240,473; Bengaluru 239,915; Chennai 239,890; Kolkata 239,886; Lucknow 239,869; Hyderabad 239,734; Jaipur 239,702; Delhi 239,643. The spread is under 1%, so 10 city shards (or city groups on fewer servers) would be even. This dataset is generated to be even, so real cities will not be;  a large city would later be split by locality.
- **Cross-shard queries:** R14 (agent leaderboard), R18, R20 and R25 aggregate over all cities, R22 and R23 look at all listings or all users, and users/builders/projects are shared across cities. Plan: keep `users`, `builders`, `projects` and reference tables replicated on every shard, and run the national aggregates as per-shard partial aggregates merged by a coordinator (or from summary tables, 6.4).

### 6.3 Read replicas and caching
- Search (R01, R02, R05, R15) is read-only and the hottest path: serve it from 1 to 3 streaming replicas; accept replication lag of a few seconds for listing data.
- The writes (W01 to W05) stay on the primary. W04 would run in chunks (by partition or locality) to keep each transaction short and replica lag small.
- Cache the most repeated results (a locality's top listings, project pages: R10, R11) in an application cache with a short TTL.

### 6.4 Maintenance
- **Autovacuum:** `properties` is updated in place (status, price). With fillfactor 80 and no index on `status`, most updates are HOT (97% in W04), so lower `autovacuum_vacuum_scale_factor` for `properties` (for example 0.02) and monitor dead tuples.
- **Archiving:** detach partitions of listings that stayed SOLD/RENTED/INACTIVE for over a year.
- **Summary tables** for the whole-table reports (R14, R18, R20, R25), refreshed hourly, to keep them under their targets as data grows: they are the queries that grew most.
- Re-run `ANALYZE` after each bulk load; keep `work_mem` high enough for the R25 and R09 hash tables (or use the rewrites above).

## 7. Conclusion and risks

- The indexing strategy holds on the official large data: 24 of 30 targets met and the sum of timings grew 21.6x for 20x the data.
- The six misses are R01, R02, R09, R12, R17 and W04. For R01, R02 and W04 the cause is measured and the alternatives we tried (CLUSTER, status-partial indexes) made W04 much slower. R09 (262 ms vs 250) and R12 (286 ms vs 250) are close to the line; we found the cause in their plans (section 4.3) but did not test a different design for them, and R17 is an hourly job.
- **Risks:** (1) the timings come from a cloud container, not a laptop, and R09 and R12 are within 5 to 15% of their targets, so a faster or slower machine can move them across the line; (2) the I8 check shows 1,080,429 properties with no project, so any query that relies on `project_id` has to treat NULL carefully (this was the R13 bug); (3) partitioning and sharding are designed, not run at 100x; (4) R22's keyset "last seen" anchor is recomputed from the loaded data by `run_large.sh` (the last row of page 2,000): (2026-06-19 10:09:58+00, 2350123) on the official data, instead of the seed literal in `sql/06_optimized_queries.sql`.
