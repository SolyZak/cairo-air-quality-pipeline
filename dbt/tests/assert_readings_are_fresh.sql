-- FRESHNESS: fail if the newest measurement is more than 48 hours old.
--
-- A singular test (one .sql file returning offending rows) rather than a
-- `dbt source freshness` config, because this has to run inside `dbt test` --
-- which is what CI executes. Source freshness is configured as well, in
-- _staging__sources.yml, but it answers a different question: it measures how
-- long since the LOADER last wrote, whereas this measures how old the newest
-- MEASUREMENT is. A pipeline that runs perfectly against an API serving stale
-- data passes the first and fails this one.
--
-- 48 hours, not 24: the DAG runs daily, so a single missed run is normal
-- operational noise. Two consecutive misses is a problem worth waking up for.

select
    max(measured_at_utc)                        as latest_reading_utc,
    now() - max(measured_at_utc)                as staleness

from {{ ref('fct_hourly_readings') }}

having now() - max(measured_at_utc) > interval '48 hours'
