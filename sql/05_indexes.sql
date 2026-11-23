-- =====================================================================
-- Phase 4: indexes for the 30-query workload  (DolFin, team T0019)
-- Run order:  01_schema.sql -> 02_load_data.sql -> THIS FILE -> (benchmark)
-- Baseline had only the 20 PK/UNIQUE indexes. Every index below says which queries it
-- serves and why that type and column order were chosen.
-- Rules followed: no server setting changed, no data changed, no row deleted.
--
-- DESIGN RULE: no index mentions properties.status (not as a key, an INCLUDE column or a
-- partial-index predicate). In PostgreSQL an UPDATE can be "HOT" (no new index entries) only
-- if no indexed column changes AND the new row version fits on the same page. W04 flips
-- status on ~12% of the table every night. Measured W04 (3 runs, avg):
--     baseline (PK only)                               111 ms
--     status inside 6 indexes (key, INCLUDE, partial)        302 ms   <- rejected
--     no status in any index, fillfactor 100           479 ms   (no room on the page, so not HOT)
--     no status in any index, fillfactor 90            201 ms
--     no status in any index, fillfactor 80  (FINAL)    89 ms
-- Raw plans: benchmarks/results/optimized/experiments/ and .../optimized/W04.txt
-- Searches therefore check status on the few rows the index already found, which is cheap.
-- =====================================================================
SET search_path TO housing;

-- ---------------------------------------------------------------------
-- 0. Leave room on each page of `properties` so status updates can be HOT.
--    VACUUM FULL rewrites the table once (exclusive lock; fine here, in production do it
--    in a maintenance window or set the fillfactor before loading the data).
-- ---------------------------------------------------------------------
ALTER TABLE properties SET (fillfactor = 80);
VACUUM FULL properties;

-- ---------------------------------------------------------------------
-- properties (120,060 rows)
-- ---------------------------------------------------------------------

-- Serves R01, R02, R04, R15, R19.
-- All five filter on locality first (R02/R15/R19 through localities.city_id = a handful of
-- locality_ids, R01/R04 on one locality), then on listing_type, property_type and bhk
-- (equality), and R01/R02 end with a price range / sort. So: equality columns first
-- (locality_id, listing_type, property_type, bhk) and the range column price last.
-- INCLUDE holds every other column those queries read (area, furnishing, available_from,
-- posted_at) so R04 and R15 are Index Only Scans and R01/R02 only visit the table to check
-- status on a few dozen rows.
CREATE INDEX idx_prop_search ON properties (locality_id, listing_type, property_type, bhk, price)
  INCLUDE (carpet_area_sqft, furnishing, available_from, posted_at);

-- Serves R06, R07, W02, W05.
-- "Everything owner/agent X listed". listed_by first (equality), listing_type second, and
-- property_id last so W02's max(property_id) and W05's min(property_id) read the end of one
-- index range instead of walking the whole primary key (3,150 and 53,025 rows skipped in
-- the baseline plans).
CREATE INDEX idx_prop_lister ON properties (listed_by, listing_type, property_id);

-- Serves R09, R11, R13.
-- project_id is a foreign key, which PostgreSQL does not index. price / bhk / listing_type
-- are the columns R09 (rank by price) and R11 (group by bhk, listing_type, min/max price)
-- read; R13 only needs to know whether a project_id exists (Index Only Scan, and NULLs are
-- stored in a B-tree so the 54,009 project-less listings cost only index space).
CREATE INDEX idx_prop_project ON properties (project_id) INCLUDE (price, bhk, listing_type);

-- Serves R20, R22 (and the 'older than 90/120 days' tests of R17 and W04).
-- Time-ordered access. DESC + property_id matches R22's ORDER BY posted_at DESC, property_id
-- DESC so the keyset page reads exactly 25 index entries; the range on posted_at makes R20
-- an Index Only Scan of one month.
CREATE INDEX idx_prop_posted ON properties (posted_at DESC, property_id DESC)
  INCLUDE (listed_by, listing_type, price);

-- Serves R05.
-- Map view: rentals in a latitude/longitude box, LIMIT 200. listing_type first (equality),
-- latitude (range) second, longitude third so the box test is done inside the index;
-- price and bhk are included to avoid reading the table until the 200 rows are found.
-- A plain B-tree is enough here because the box is narrow in latitude; PostGIS/GiST would
-- be the next step for arbitrary map shapes.
CREATE INDEX idx_prop_map ON properties (listing_type, latitude, longitude) INCLUDE (price, bhk);

-- ---------------------------------------------------------------------
-- enquiries (100,000 rows): foreign keys are NOT indexed by PostgreSQL
-- ---------------------------------------------------------------------

-- Serves R06, R17, R19, R25.
-- All look up enquiries of a property (R25 and the uniqueness of a lead also by user).
-- created_at is included so R19's count and max(created_at) come from the index alone.
CREATE INDEX idx_enq_property_user ON enquiries (property_id, user_id) INCLUDE (created_at);

-- Serves R12.
-- Date window on enquiries.created_at (a few weeks of 18 months of data); property_id and
-- user_id are included because they are the anti-join keys against site_visits.
CREATE INDEX idx_enq_created ON enquiries (created_at) INCLUDE (property_id, user_id);

-- ---------------------------------------------------------------------
-- site_visits (35,120 rows)
-- ---------------------------------------------------------------------

-- Serves R06, R07, R12.
-- property_id first: R06 counts visits per property, R07 reaches visits through the
-- lister's properties, R12 anti-joins on (property_id, user_id). scheduled_at and visit_id
-- are included for R07's date test and R06's count.
CREATE INDEX idx_visit_property_user ON site_visits (property_id, user_id)
  INCLUDE (scheduled_at, visit_id);

-- ---------------------------------------------------------------------
-- Deliberately NOT indexed (tried in an earlier design where status was indexed; raw plans in
-- benchmarks/results/optimized/experiments/design_A_status_indexed/, baseline numbers in brackets)
--   R03, R10, R23  already use PK/UNIQUE indexes (0.04-0.2 ms).
--   R08  an index on price_changes(changed_at) gave 2.2 ms [2.6]: 23k rows is too small for it to matter.
--   R14, R18  a partial index WHERE status IN (...) / = 'ACTIVE' gave 8.5 ms [19.4] and 8.3 ms [26.8],
--        but needs status in an index -> W04 goes from HOT updates to full index maintenance
--        (302 ms [111]). Both reports sit far inside their large-data target (5,000 ms).
--   R17, R21  anti-join / aggregation bound: they must read most of one table; the best index
--        tried gave 21.2 ms [22.7] for R21 and nothing for R17.
--   R16  projects has 1,200 rows; a pg_trgm GIN index would not be chosen over a 0.5 ms
--        Seq Scan (revisit when projects is far larger).
--   R24  projects / builders are tiny (1,200 / 150 rows).
-- ---------------------------------------------------------------------
VACUUM (ANALYZE);
