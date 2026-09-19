-- ---------------------------------------------------------------------------
-- Deterministic fixture for CI.
--
-- CI does NOT call Open-Meteo. A test suite that fails because someone else's
-- API is having a bad morning teaches you nothing and trains you to ignore red
-- builds. The ingestion code's contract with the API is enforced by the guards
-- in ingestion/open_meteo.py; what CI checks here is the dbt layer -- the
-- models, the keys, the ranges and the freshness rule.
--
-- Timestamps are generated RELATIVE TO now() so the 48-hour freshness test is
-- exercised honestly rather than pinned to a date that would eventually rot.
-- ---------------------------------------------------------------------------

begin;

with response as (

    insert into raw.air_quality_responses
        (request_url, request_params, window_start, window_end,
         http_status, payload, payload_sha256)
    values (
        'https://ci.invalid/fixture',
        '{"source": "ci-fixture"}'::jsonb,
        (now() - interval '3 days')::date,
        now()::date,
        200,
        '{"note": "synthetic fixture, no API call"}'::jsonb,
        repeat('0', 64)
    )
    returning response_id

),

hours as (

    -- 72 hourly slots ending at the current hour. date_trunc keeps them on the
    -- hour, which staging.hourly_readings enforces with a CHECK constraint --
    -- so a bug in this fixture fails loudly rather than seeding bad data.
    select generate_series(
        date_trunc('hour', now()) - interval '71 hours',
        date_trunc('hour', now()),
        interval '1 hour'
    ) as measured_at_utc

)

insert into staging.hourly_readings
    (location_code, pollutant_code, measured_at_utc, value, unit, source_response_id)
select
    'cairo',
    p.pollutant_code,
    h.measured_at_utc,
    case
        -- A handful of deliberate NULLs. The API returns null for hours it has
        -- no data for, so if a test cannot cope with one, CI should say so.
        when extract(hour from h.measured_at_utc)::int = 4 then null
        else round(
            (25 + 10 * sin(extract(epoch from h.measured_at_utc) / 7200.0)
                + p.sort_order * 6)::numeric,
            3
        )
    end,
    p.unit,
    r.response_id
from hours h
cross join staging.pollutants p
cross join response r;

commit;

\echo 'fixture loaded:'
select count(*) as readings,
       count(value) as non_null,
       min(measured_at_utc) as earliest,
       max(measured_at_utc) as latest
from staging.hourly_readings;
