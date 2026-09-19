-- ---------------------------------------------------------------------------
-- Warehouse schemas.
--
-- Three layers, one schema each, so a query's schema prefix tells you how much
-- to trust what you are reading:
--
--   raw        exactly what the API returned, append-only, never edited.
--              Replayable: if a transform is wrong we can rebuild from here.
--   staging    one typed, deduplicated row per real-world measurement.
--              This is the idempotency boundary -- re-running a day upserts.
--   analytics  dbt's output: the star schema the dashboards/tests read.
--
-- dbt owns `analytics` and will create objects there itself. It is created
-- here so the grant exists before dbt's first run.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS analytics;

COMMENT ON SCHEMA raw       IS 'Immutable landing zone: API responses as received, with ingestion metadata.';
COMMENT ON SCHEMA staging   IS 'Typed and deduplicated measurements. Natural-key upsert target; safe to re-run.';
COMMENT ON SCHEMA analytics IS 'dbt-managed star schema (dim_date, dim_pollutant, fct_hourly_readings).';
