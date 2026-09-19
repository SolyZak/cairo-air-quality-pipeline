{{
    config(
        materialized = 'incremental',
        unique_key = ['location_code', 'pollutant_key', 'measured_at_utc'],
        incremental_strategy = 'delete+insert',
        on_schema_change = 'append_new_columns'
    )
}}

-- Fact table. Grain: one row per location, pollutant and hour -- the same
-- grain as staging.hourly_readings, because that is the grain at which the
-- measurement actually exists.
--
-- ---------------------------------------------------------------------------
-- Why incremental rather than a full rebuild
-- ---------------------------------------------------------------------------
-- A full refresh of this model is cheap today (a few thousand rows) and would
-- be simpler. It is still the wrong default, because the thing that makes a
-- rebuild expensive is not the row count -- it is the retention window. This
-- table grows by 96 rows a day and nothing ever deletes from it; a year of
-- four pollutants at one location is ~35k rows, and a second city or a
-- finer-grained pollutant list multiplies that. Rewriting the entire history
-- every night to add one day of data is work that scales with the age of the
-- project rather than with the size of the change.
--
-- The incremental filter is on `loaded_at`, the loader's watermark, not on
-- `measured_at_utc`. That distinction matters: filtering on measurement time
-- would miss a value the API REVISED for an hour we already hold. The loader
-- only moves `loaded_at` when a value actually changes (its upsert carries an
-- `IS DISTINCT FROM` guard), so this picks up exactly the new and corrected
-- rows and nothing else.
--
-- `>=` rather than `>`: rows written inside the same transaction share a
-- timestamp, and re-processing a handful of rows is free because
-- `delete+insert` on the unique key is idempotent. Missing one would not be.
--
-- `dbt run --full-refresh` rebuilds from scratch whenever the logic changes.
-- ---------------------------------------------------------------------------

with readings as (

    select * from {{ ref('stg_hourly_readings') }}

    {% if is_incremental() %}
    where loaded_at >= (
        select coalesce(max(source_loaded_at), '1900-01-01'::timestamptz)
        from {{ this }}
    )
    {% endif %}

),

pollutants as (

    select * from {{ ref('dim_pollutant') }}

)

select
    -- Surrogate key over the natural key. Its only job is to let dbt's built-in
    -- `unique` test -- which takes a single column -- police a three-column
    -- grain. The alternative is dbt_utils.unique_combination_of_columns, and
    -- adding a package dependency for one test is a poor trade.
    md5(
        r.location_code || '|' || r.pollutant_code || '|' ||
        to_char(r.measured_at_utc at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS')
    )                                                   as reading_key,

    -- Foreign keys
    to_char(r.measured_at_cairo, 'YYYYMMDD')::int       as date_key,
    r.pollutant_code                                    as pollutant_key,
    r.location_code,

    -- Degenerate dimensions: the exact instant, both ways.
    r.measured_at_utc,
    r.measured_at_cairo,
    extract(hour from r.measured_at_cairo)::int         as hour_of_day_cairo,

    -- Measures
    r.concentration,
    r.unit,

    -- Derived flag rather than a stored one. NULL concentration gives NULL
    -- here, not false: "we do not know" and "it was within guideline" are
    -- different answers and should not be collapsed.
    case
        when r.concentration is null then null
        else r.concentration > p.who_guideline
    end                                                 as exceeds_who_guideline,

    -- Lineage
    r.source_response_id,
    r.loaded_at                                         as source_loaded_at

from readings r
inner join pollutants p
    on r.pollutant_code = p.pollutant_key
