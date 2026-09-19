-- ---------------------------------------------------------------------------
-- staging.pollutants  -- small reference table, the domain of what we ingest.
--
-- Why a table and not a dbt seed or a CHECK constraint:
--   * A CHECK list would have to be edited with ALTER TABLE.
--   * A dbt seed only exists after dbt runs, so the *loader* could not
--     validate against it -- an API typo like 'pm25' would sail into staging
--     and only surface hours later as a broken dimension.
--   * As a table with a foreign key, a pollutant we did not plan for makes the
--     load fail loudly, at the point of the mistake. That is the behaviour we
--     want: fail fast, not fail quietly.
--
-- dim_pollutant in stage 4 is built from this table.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS staging.pollutants (
    -- The Open-Meteo variable name, used verbatim as the API request field.
    -- Keeping the source's spelling means no translation layer in the loader.
    pollutant_code      text        PRIMARY KEY,

    -- How a human writes it (dashboards, axis labels).
    display_name        text        NOT NULL,
    unit                text        NOT NULL,

    -- WHO 2021 air quality guideline for the averaging period noted below.
    -- Not a validation bound -- a reference line for charts and a "was this a
    -- bad day?" flag in the fact table.
    who_guideline       numeric(10,3),
    who_averaging_hours smallint,

    -- Upper bound for plausibility testing. Values above this are physically
    -- possible only in an extreme event and far more likely to be a unit
    -- error or a sentinel value. stage 4's accepted_range test joins here
    -- instead of hardcoding four sets of literals in schema.yml -- bounds are
    -- data, so they live in a table and can be changed without a code review.
    plausible_max       numeric(10,3) NOT NULL,

    sort_order          smallint    NOT NULL,

    CONSTRAINT pollutants_plausible_max_ck CHECK (plausible_max > 0)
);

-- ON CONFLICT DO UPDATE rather than DO NOTHING so that editing a bound in this
-- file and re-running scripts/apply_ddl.sh actually applies the change.
INSERT INTO staging.pollutants
    (pollutant_code,     display_name, unit,    who_guideline, who_averaging_hours, plausible_max, sort_order)
VALUES
    ('pm2_5',            'PM2.5',      'ug/m3',          15.0,                  24,        1000.0,          1),
    ('pm10',             'PM10',       'ug/m3',          45.0,                  24,        2000.0,          2),
    ('nitrogen_dioxide', 'NO2',        'ug/m3',          25.0,                  24,        1000.0,          3),
    ('ozone',            'O3',         'ug/m3',         100.0,                   8,        1000.0,          4)
ON CONFLICT (pollutant_code) DO UPDATE SET
    display_name        = EXCLUDED.display_name,
    unit                = EXCLUDED.unit,
    who_guideline       = EXCLUDED.who_guideline,
    who_averaging_hours = EXCLUDED.who_averaging_hours,
    plausible_max       = EXCLUDED.plausible_max,
    sort_order          = EXCLUDED.sort_order;

COMMENT ON TABLE staging.pollutants IS 'Reference domain for ingested pollutants. Source of dim_pollutant.';


-- ---------------------------------------------------------------------------
-- staging.hourly_readings  -- the idempotency boundary.
--
-- Grain: ONE row per (location, pollutant, hour). That grain is the whole
-- design. Because the primary key is the natural key of a real-world
-- measurement, the loader can use
--
--     INSERT ... ON CONFLICT (location_code, pollutant_code, measured_at_utc)
--     DO UPDATE SET ...
--
-- and re-running the same day is a no-op on row count. Nothing else in the
-- pipeline needs to know whether it has run before -- no "have I loaded this
-- already?" bookkeeping table, no DELETE-then-INSERT window where the table is
-- half empty. The database enforces it.
--
-- This is also why the daily DAG pulls a 7-day window instead of 1 day: the
-- overlap silently repairs any day the API had not finalised yet, and the
-- upsert makes that overlap free.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS staging.hourly_readings (
    -- Cairo is the only location today. The column exists anyway because the
    -- grain is honest about it: adding a second city must not require
    -- rewriting the primary key of a table that already has data in it.
    location_code   text        NOT NULL,

    pollutant_code  text        NOT NULL
        REFERENCES staging.pollutants (pollutant_code),

    -- UTC, always. The API is called with timezone=UTC and this column stores
    -- timestamptz. Cairo local time (UTC+2, UTC+3 under DST) is DERIVED in
    -- dbt, never stored as the key -- storing local time would make one hour
    -- ambiguous and one hour missing every year at the DST boundary, and the
    -- primary key would silently reject or mangle those rows.
    measured_at_utc timestamptz NOT NULL,

    -- Nullable on purpose. Open-Meteo returns null for hours it has no data
    -- for. Dropping those rows would hide the gap; storing the null makes it
    -- visible to a coverage check and keeps the hourly series complete.
    value           numeric(10,3),

    unit            text        NOT NULL,

    -- Which API call this value came from. Makes every fact row traceable back
    -- to the exact response in raw -- the question "where did this number come
    -- from?" has a one-join answer.
    source_response_id bigint   NOT NULL
        REFERENCES raw.air_quality_responses (response_id),

    -- first_loaded_at never moves. loaded_at moves only when the value
    -- actually changes -- the loader's ON CONFLICT carries an
    -- `IS DISTINCT FROM` guard, so re-ingesting identical data writes nothing.
    -- The pair therefore answers "was this reading ever revised?".
    first_loaded_at timestamptz NOT NULL DEFAULT now(),
    loaded_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT hourly_readings_pk
        PRIMARY KEY (location_code, pollutant_code, measured_at_utc),

    -- Concentrations cannot be negative. This is a *hard impossibility*, so
    -- the database rejects it. Implausible-but-possible values (PM2.5 of 900)
    -- are checked by dbt instead: the split is deliberate -- the DB refuses
    -- data that cannot exist, dbt reports data that should not exist.
    CONSTRAINT hourly_readings_value_ck CHECK (value IS NULL OR value >= 0),

    -- Readings must land on the hour. Catches a timezone or rounding bug in
    -- the loader immediately rather than as a duplicate-looking dimension.
    CONSTRAINT hourly_readings_on_the_hour_ck
        CHECK (date_trunc('hour', measured_at_utc) = measured_at_utc)
);

-- dbt's incremental model and the freshness test both ask "what is the latest
-- measured_at_utc?" and "what changed since X?".
CREATE INDEX IF NOT EXISTS hourly_readings_measured_at_ix
    ON staging.hourly_readings (measured_at_utc DESC);

CREATE INDEX IF NOT EXISTS hourly_readings_loaded_at_ix
    ON staging.hourly_readings (loaded_at DESC);

COMMENT ON TABLE  staging.hourly_readings                    IS 'One row per location/pollutant/hour. Natural-key PK makes the load idempotent.';
COMMENT ON COLUMN staging.hourly_readings.measured_at_utc    IS 'Hour of measurement in UTC. Cairo local time is derived downstream, never stored as key.';
COMMENT ON COLUMN staging.hourly_readings.value              IS 'Concentration. NULL means the API reported no data for this hour -- the gap is kept, not dropped.';
COMMENT ON COLUMN staging.hourly_readings.first_loaded_at    IS 'When this measurement was first seen. Unchanged by later upserts.';
COMMENT ON COLUMN staging.hourly_readings.loaded_at          IS 'When this row''s value last CHANGED. The loader skips no-op upserts, so a re-run of unchanged data does not move it.';
