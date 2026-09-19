-- Per-pollutant plausibility. The generic accepted_range test in
-- _marts__models.yml catches values that are absurd for ANY pollutant; this
-- catches values that are implausible for a SPECIFIC one, using the bound
-- stored on the dimension.
--
-- The bounds live in staging.pollutants rather than as literals in a YAML
-- file, so tightening PM10 from 2000 to 1200 is a data change, not a code
-- change -- and the loader and the tests can never disagree about them.

select
    f.reading_key,
    f.pollutant_key,
    f.measured_at_utc,
    f.concentration,
    p.plausible_max

from {{ ref('fct_hourly_readings') }} f
inner join {{ ref('dim_pollutant') }} p
    on f.pollutant_key = p.pollutant_key

where f.concentration is not null
  and f.concentration > p.plausible_max
