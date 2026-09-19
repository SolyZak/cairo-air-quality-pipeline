-- Thin staging layer: rename, cast, and derive Cairo local time. No filtering
-- and no aggregation -- anything that drops rows belongs in a mart, where it
-- is visible, not in a view everything else is built on.

select
    location_code,
    pollutant_code,

    measured_at_utc,

    -- Cairo is UTC+2, UTC+3 under DST. The warehouse stores UTC (see the
    -- README), and local time is derived HERE rather than at load time so that
    -- a change to Egypt's DST rules is a `dbt run` away instead of a reload.
    --
    -- `timestamptz AT TIME ZONE 'Africa/Cairo'` yields a `timestamp without
    -- time zone`: the wall-clock reading a person in Cairo would see.
    (measured_at_utc at time zone 'Africa/Cairo') as measured_at_cairo,

    value as concentration,
    unit,

    -- Lineage back to the exact API response, and the loader's watermark --
    -- the incremental fact reads this to find what changed.
    source_response_id,
    first_loaded_at,
    loaded_at

from {{ source('staging', 'hourly_readings') }}
