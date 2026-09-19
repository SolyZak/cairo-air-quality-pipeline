-- Calendar dimension, one row per day.
--
-- The spine is generated from the range actually present in the readings
-- rather than a hardcoded 2000-2050 span: a dimension full of dates the fact
-- table has never heard of makes every "days with no data" check useless,
-- because an empty day and a missing day become indistinguishable.
--
-- The grain is the CAIRO calendar day, not the UTC one. "What was PM2.5 on
-- Tuesday" means Tuesday in Cairo -- and with a +2/+3 offset the two calendars
-- disagree for two or three hours of every day.

with bounds as (

    select
        min(measured_at_cairo)::date as first_day,
        max(measured_at_cairo)::date as last_day
    from {{ ref('stg_hourly_readings') }}

),

spine as (

    select generate_series(first_day, last_day, interval '1 day')::date as date_day
    from bounds

)

select
    -- YYYYMMDD as an integer. A readable surrogate key: you can eyeball a fact
    -- row and know the date without joining, which is worth a lot when
    -- debugging, and it sorts chronologically for free.
    to_char(date_day, 'YYYYMMDD')::int          as date_key,

    date_day,

    extract(year    from date_day)::int         as year,
    extract(quarter from date_day)::int         as quarter,
    extract(month   from date_day)::int         as month,
    to_char(date_day, 'Month')                  as month_name,
    extract(day     from date_day)::int         as day_of_month,

    -- ISO day of week: Monday = 1 ... Sunday = 7.
    extract(isodow  from date_day)::int         as day_of_week,
    to_char(date_day, 'Day')                    as day_name,
    extract(week    from date_day)::int         as iso_week,

    -- Egypt's weekend is FRIDAY and SATURDAY, not Saturday and Sunday. Using
    -- the western default here would put the weekly traffic-pollution trough
    -- on the wrong days and quietly invert any weekday/weekend comparison.
    extract(isodow from date_day)::int in (5, 6) as is_weekend

from spine
