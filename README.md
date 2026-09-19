# Cairo Air Quality Pipeline

Daily pipeline: Open-Meteo Air Quality API -> Postgres -> dbt star schema, orchestrated by Airflow, all in Docker Compose.

> **Build status: stage 2 of 5.** Postgres, schema DDL and the ingestion
> CLI are in place. Stages 3-5 (Airflow, dbt, CI + full README) follow.

## Architecture

```
Open-Meteo API
      |
      v
raw.air_quality_responses      append-only, one row per HTTP call, ingested_at
      |
      v
staging.hourly_readings        one row per (location, pollutant, hour)
      |                        PK = natural key -> upsert -> idempotent
      v
analytics.*                    dbt: dim_date, dim_pollutant, fct_hourly_readings
```

## What is here

```
docker-compose.yml           postgres:16, single service
.env.example                 committed; .env is gitignored
sql/00_create_airflow_db.sh  creates Airflow's metadata DB alongside the warehouse
sql/01_schemas.sql           raw / staging / analytics
sql/02_raw.sql               raw.air_quality_responses
sql/03_staging.sql           staging.pollutants, staging.hourly_readings
scripts/apply_ddl.sh         re-apply DDL to a running database
scripts/psql.sh              psql shell on the warehouse

ingestion/config.py          settings from the environment, validated once
ingestion/open_meteo.py      API client + parsing, with four upstream guards
ingestion/loader.py          raw insert, idempotent staging upsert
ingestion/pipeline.py        fetch -> raw -> staging, chunked by date window
ingestion/__main__.py        the CLI
Dockerfile                   python:3.12-slim runner for the CLI
requirements.txt             requests, psycopg2-binary
```

## Ingest some data

The CLI runs in its own container, so there is no Python to install:

```bash
docker compose run --rm ingest --days 7                       # a scheduled run
docker compose run --rm ingest --start 2026-08-01 --end 2026-08-31   # backfill
docker compose run --rm ingest --dry-run                      # fetch, write nothing
```

It is safe to run repeatedly. The log line to watch is:

```
staging.hourly_readings <- submitted=624 inserted=0 changed=0 unchanged=624
```

`unchanged=624` on a second run is the idempotency working: the rows were
already there with the same values, so nothing was written.

## Run it

```bash
cp .env.example .env
docker compose up -d
./scripts/psql.sh -c '\dt raw.*' -c '\dt staging.*'
```

Tear down, keeping data:

```bash
docker compose down
```

Tear down and wipe the database (next `up` re-runs all DDL from scratch):

```bash
docker compose down -v
```

## Design decisions

**One Postgres container, two databases.** `airquality` is the warehouse;
`airflow` is Airflow's own metadata store. Separate databases because Airflow's
scheduler state and analytics data have nothing to do with each other and
should not share a blast radius — but one container, because two would double
the memory for no learning value locally.

**Three schemas, not three databases.** `raw` / `staging` / `analytics` in one
database keeps cross-layer joins and dbt's `ref()` simple. The schema prefix is
the trust signal.

**`raw` is append-only.** Every API call gets a row, even if the payload is
byte-identical to yesterday's. That is the audit trail: when a number looks
wrong six weeks from now, the original response is still there to replay from.
Deduplication is staging's job, not raw's.

**The staging primary key *is* the natural key.** `(location_code,
pollutant_code, measured_at_utc)`. This is the load's idempotency mechanism:
`INSERT ... ON CONFLICT DO UPDATE` means re-running a day changes no row count
and there is no window where the table sits half-empty. No bookkeeping table
tracking which days have been loaded — the constraint does the work.

**UTC in the key, local time derived.** Cairo is UTC+2, UTC+3 under DST. If
local time were the key, one hour would be duplicated and one missing every
year at the DST boundary, and the primary key would reject or mangle them. The
API is called with `timezone=UTC`, the column is `timestamptz`, and Cairo local
time is computed in dbt where being wrong is cheap to fix.

**Null values are stored, not dropped.** The API returns null for hours it has
no data for. Keeping the row makes the gap countable; dropping it makes the
series look complete when it isn't.

**Constraint split: database vs dbt.** The database rejects what is
*impossible* — negative concentrations, timestamps not on the hour, an unknown
pollutant code (enforced by a foreign key to `staging.pollutants`). dbt reports
what is *implausible* — a PM2.5 reading of 900. Impossible data should never
land; implausible data should land and raise a flag.

**`plausible_max` lives in a table, not in `schema.yml`.** Stage 4's range test
joins `staging.pollutants` instead of hardcoding four sets of literals. Bounds
are data; they should be changeable without editing test code.

**No migration tool.** `scripts/apply_ddl.sh` re-runs idempotent DDL; it cannot
drop a column or change a type. At this size, a schema change means
`docker compose down -v` and a rebuild from `raw` — which the append-only raw
layer makes safe. Alembic or Flyway would be the answer on a real team.

**Two layers of retry, not one.** The HTTP session retries 3 times seconds
apart for blips (429, 5xx, dropped connections); Airflow will retry the task
minutes apart for outages. One layer alone either hammers a dead service or
fails a whole run over a hiccup.

**Forecast hours are dropped.** Open-Meteo returns the rest of today as
prediction — a 7-day request made at 11:34 UTC came back with 12 forecast
hours attached. Writing those into a table named `hourly_readings` would
poison every downstream average and make a freshness check pass on data that
does not exist yet. The loader keeps only hours at or before `now()`.

**The unit is asserted, not assumed.** The API reports `μg/m³` using GREEK
SMALL LETTER MU (U+03BC), not the visually identical MICRO SIGN (U+00B5).
Both are normalised to `ug/m3` and then checked against
`staging.pollutants.unit`. If the API ever switched to mg/m³ every number
would silently become 1000× wrong; an unrecognised unit is a hard failure.

**`raw` commits before `staging`.** Two transactions, not one. A payload that
breaks the parser is exactly the payload worth keeping, and a single
transaction would roll back the evidence along with the failure. The cost is
that a failed run can leave a raw row with no staging rows — which is a
useful queue of things to investigate, not a leak.

**No-op upserts are skipped.** The `ON CONFLICT DO UPDATE` carries
`WHERE value IS DISTINCT FROM EXCLUDED.value`. `IS DISTINCT FROM` rather than
`<>` because `value` is nullable and `NULL <> NULL` is `NULL`, not true — a
plain `<>` would rewrite every null row on every run. This keeps `loaded_at`
meaning "when this value last changed" and makes the unchanged count in the
log a real measure of idempotency.

**Long ranges are chunked.** A backfill splits into 31-day windows. One
request for a year would produce a single enormous JSON document in one raw
row: slow to insert, awkward to inspect, and all-or-nothing on failure.

**Airflow imports `run_window()`; it does not shell out.** The `ingest`
service stays as the manual entry point, but stage 3's DAG calls the same
Python function directly — so there is one code path, not two that can drift.
