-- Pollutant dimension, straight from the reference table the loader validates
-- against. Four rows.
--
-- The natural key is used as the dimension key rather than a generated
-- surrogate. For a tiny, static domain whose codes come from the source API
-- and will not change, a surrogate buys nothing and costs readability: you can
-- read `where pollutant_key = 'pm2_5'` without joining. A slowly-changing
-- dimension, or one with a volatile key, would need the surrogate.

select
    pollutant_code                              as pollutant_key,
    display_name,
    unit,

    -- WHO 2021 guideline for the averaging period in who_averaging_hours.
    -- A reference line for charts, not a validation bound.
    who_guideline,
    who_averaging_hours,

    -- Upper bound for plausibility testing. Read by
    -- tests/assert_concentration_within_pollutant_bounds.sql, so the bounds
    -- are data rather than literals buried in a YAML file.
    plausible_max,

    sort_order

from {{ source('staging', 'pollutants') }}
