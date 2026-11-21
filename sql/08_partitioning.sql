-- =====================================================================
-- Phase 5: partitioning design for `properties`  (DolFin, team T0019)
-- Builds a PARTITIONED COPY in schema housing_part (the real table in schema housing is NOT touched),
-- loads it from housing.properties and shows partition pruning with EXPLAIN.
-- Run after sql/01, 02, 05:   psql -d <db> -f sql/08_partitioning.sql
--
-- WHY RANGE ON posted_at, MONTHLY
--   * Listings arrive in time order and are queried by time (R20 growth, R22 newest-first console, R17/W04
--     'older than 90/120 days'), so most time filters can prune to a few partitions.
--   * Old months become read-mostly (SOLD / RENTED / INACTIVE): they can be vacuumed once, moved to cheaper
--     storage, or DETACHed and archived without a huge DELETE.
--   * ~19 partitions for 18 months of data; 100x data would be ~19 x 100x-smaller-than-total partitions of
--     (2.4M/19 =) 126k rows each at today's 20x volume, which keeps each partition's indexes small and cacheable.
-- WHY NOT LIST BY CITY / HASH BY locality: city is a sharding key (see docs/05_scalability_report.md), but inside
--   one server the search queries R01/R02/R05 already use idx_prop_search/idx_prop_map efficiently; time is the
--   dimension along which data ages.
--
-- THE PRIMARY KEY RULE
--   Every PRIMARY KEY / UNIQUE constraint on a partitioned table MUST contain all partition-key columns.
--   So the key becomes (property_id, posted_at), not property_id alone. Consequences, all handled below:
--     1. property_id is no longer enforced unique by itself (it still is in practice: it is a sequence/id the
--        application assigns once). A separate UNIQUE (property_id) is impossible.
--     2. A foreign key can only point at a UNIQUE/PK. enquiries.property_id, site_visits.property_id,
--        shortlists.property_id and price_changes.property_id therefore CANNOT reference housing_part.properties
--        (no unique key on property_id). Options: (a) keep those FKs unenforced and rely on the application /
--        a trigger, (b) also store posted_at in the child tables and reference (property_id, posted_at),
--        (c) partition the children by the same key. We would choose (a)+(periodic orphan check), see report.
--     3. R03 (WHERE property_id = 6897) has no partition key, so it probes every partition's PK index
--        (20 small index probes instead of 1). Measured in the report.
-- =====================================================================
\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS housing_part CASCADE;
CREATE SCHEMA housing_part;

-- Same columns, defaults, NOT NULL and CHECK constraints as housing.properties (this includes the 24 CHECKs).
CREATE TABLE housing_part.properties
  (LIKE housing.properties INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
  PARTITION BY RANGE (posted_at);

ALTER TABLE housing_part.properties ADD CONSTRAINT properties_pkey PRIMARY KEY (property_id, posted_at);

-- Foreign keys FROM the partitioned table are allowed (PostgreSQL 12+).
ALTER TABLE housing_part.properties
  ADD CONSTRAINT fk_prop_lister   FOREIGN KEY (listed_by)   REFERENCES housing.users(user_id)       ON DELETE RESTRICT,
  ADD CONSTRAINT fk_prop_project  FOREIGN KEY (project_id)  REFERENCES housing.projects(project_id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_prop_locality FOREIGN KEY (locality_id) REFERENCES housing.localities(locality_id) ON DELETE RESTRICT;

-- Monthly partitions in India time (IST), Jan 2025 .. Jul 2026, plus a DEFAULT partition so a row outside
-- the range (or a late month) is never rejected. Fillfactor 80 as on the unpartitioned table (HOT updates for W04).
DO $$
DECLARE m date := DATE '2025-01-01';
BEGIN
  WHILE m < DATE '2026-08-01' LOOP
    EXECUTE format(
      'CREATE TABLE housing_part.properties_%s PARTITION OF housing_part.properties
         FOR VALUES FROM (%L) TO (%L) WITH (fillfactor = 80)',
      to_char(m, 'YYYY_MM'),
      to_char(m, 'YYYY-MM-DD') || ' 00:00:00+05:30',
      to_char(m + INTERVAL '1 month', 'YYYY-MM-DD') || ' 00:00:00+05:30');
    m := (m + INTERVAL '1 month')::date;
  END LOOP;
END $$;
CREATE TABLE housing_part.properties_default PARTITION OF housing_part.properties DEFAULT WITH (fillfactor = 80);

INSERT INTO housing_part.properties SELECT * FROM housing.properties;

-- The same five indexes as sql/05_indexes.sql; PostgreSQL creates one index per partition ("local" indexes).
-- None of them mentions status (see 05_indexes.sql, DESIGN RULE).
CREATE INDEX idx_prop_search  ON housing_part.properties (locality_id, listing_type, property_type, bhk, price)
  INCLUDE (carpet_area_sqft, furnishing, available_from, posted_at);
CREATE INDEX idx_prop_lister  ON housing_part.properties (listed_by, listing_type, property_id);
CREATE INDEX idx_prop_project ON housing_part.properties (project_id) INCLUDE (price, bhk, listing_type);
CREATE INDEX idx_prop_posted  ON housing_part.properties (posted_at DESC, property_id DESC) INCLUDE (listed_by, listing_type, price);
CREATE INDEX idx_prop_map     ON housing_part.properties (listing_type, latitude, longitude) INCLUDE (price, bhk);
VACUUM (ANALYZE) housing_part.properties;

-- ---------------------------------------------------------------------
-- Same row count and per-month distribution as the original?
-- ---------------------------------------------------------------------
SELECT (SELECT count(*) FROM housing.properties)      AS rows_original,
       (SELECT count(*) FROM housing_part.properties) AS rows_partitioned,
       (SELECT count(*) FROM housing_part.properties_default) AS rows_in_default_partition;
SELECT tableoid::regclass AS partition, count(*) AS rows
FROM housing_part.properties GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- PARTITION PRUNING: look for 'Subplans Removed' / the list of partitions actually scanned.
-- ---------------------------------------------------------------------
\echo '--- R20 (June 2026 listings, IST boundaries like the partitions): 1 partition of 20 is scanned'
EXPLAIN (COSTS OFF)
SELECT posted_at::date AS day, count(*) AS listings
FROM housing_part.properties
WHERE posted_at >= '2026-06-01 00:00:00+05:30' AND posted_at < '2026-07-01 00:00:00+05:30'
GROUP BY 1;

\echo '--- R22 keyset page: newest-first needs only the newest partitions'
EXPLAIN (COSTS OFF)
SELECT property_id, listed_by, listing_type, status, price, posted_at
FROM housing_part.properties
WHERE (posted_at, property_id) < (TIMESTAMPTZ '2025-11-15 11:18:17+00', 70045)
ORDER BY posted_at DESC, property_id DESC LIMIT 25;

\echo '--- W04 / R17 predicate (older than 120 days before 1 Jul 2026): prunes only the newest months'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM housing_part.properties
WHERE status = 'ACTIVE' AND posted_at < TIMESTAMPTZ '2026-07-01 00:00:00+05:30' - interval '120 days';

\echo '--- R01 (no time filter): NO pruning, every partition is probed'
EXPLAIN (COSTS OFF)
SELECT p.property_id FROM housing_part.properties p
WHERE p.locality_id = 1 AND p.listing_type = 'RENT' AND p.bhk = 2 AND p.price <= 40000;

\echo '--- R03 (property_id only): primary key probe in every partition'
EXPLAIN (COSTS OFF)
SELECT property_id, price FROM housing_part.properties WHERE property_id = 6897;

-- ---------------------------------------------------------------------
-- MAINTENANCE PATTERNS (documented, not executed)
--   -- next month's partition, created before the month starts (cron / pg_partman):
--   CREATE TABLE housing_part.properties_2026_08 PARTITION OF housing_part.properties
--     FOR VALUES FROM ('2026-08-01 00:00:00+05:30') TO ('2026-09-01 00:00:00+05:30') WITH (fillfactor = 80);
--   -- archive a year-old month without a DELETE (instant, takes a short lock):
--   ALTER TABLE housing_part.properties DETACH PARTITION housing_part.properties_2025_01;
--   -- then pg_dump it / move it to a tablespace on cheap storage / drop it.
-- ---------------------------------------------------------------------
