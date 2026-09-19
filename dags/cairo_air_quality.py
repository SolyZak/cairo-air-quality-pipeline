"""Daily Cairo air quality ingestion.

Airflow orientation, since this is the first DAG in the project:

  * A DAG is a schedule plus a graph of tasks. This file is not "the pipeline" --
    the pipeline lives in the `ingestion` package. The DAG only decides WHEN to
    call it and WHAT date window to ask for. Keeping the work outside the DAG is
    what lets you run the exact same code from the CLI with no scheduler.

  * Every scheduled run covers a DATA INTERVAL, not "now". A daily DAG run for
    2026-09-18 has data_interval_start = 2026-09-18T00:00 and
    data_interval_end = 2026-09-19T00:00. Deriving the window from the interval
    -- rather than from today's date -- is the single thing that makes backfill
    work: a run for a date last month pulls last month's data, not this
    morning's.

  * `catchup=False` means turning the DAG on does not immediately schedule every
    missed day since start_date. Backfills are run deliberately instead, with
    `airflow backfill create` (see the README).
"""

from __future__ import annotations

import logging
from datetime import timedelta

import pendulum
from airflow.sdk import dag, get_current_context, task

from ingestion.config import Settings
from ingestion.loader import connect
from ingestion.pipeline import run_window

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Retry policy, applied to every task in the DAG.
#
# retry_exponential_backoff spaces the attempts out instead of retrying at a
# fixed interval: with retry_delay=2min the waits are roughly 2, 4, 8 and 16
# minutes, capped by max_retry_delay. Total window before the run is declared
# failed is about half an hour.
#
# The reasoning: the HTTP client already retries seconds apart for blips (see
# ingestion/open_meteo.py). Anything that survives that is an actual outage --
# the API is down, the database is restarting -- and outages need time, not
# repetition. A fixed 2-minute retry would burn all four attempts inside eight
# minutes and fail a run that would have succeeded at minute twenty.
# ---------------------------------------------------------------------------
DEFAULT_ARGS = {
    "retries": 4,
    "retry_delay": timedelta(minutes=2),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=30),
}


@dag(
    dag_id="cairo_air_quality_daily",
    description="Ingest Cairo hourly air quality from Open-Meteo into Postgres.",
    # 03:00 UTC: late enough that the previous day is settled upstream, early
    # enough that a failure still has a working day left to be noticed in.
    schedule="0 3 * * *",
    start_date=pendulum.datetime(2026, 9, 1, tz="UTC"),
    catchup=False,
    # Exactly one run at a time. Two runs would be upserting overlapping windows
    # into the same primary key range concurrently -- correct, thanks to
    # ON CONFLICT, but a good way to generate lock contention and deadlocks for
    # no benefit. It also keeps a backfill sequential and readable.
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    tags=["air-quality", "ingestion", "open-meteo"],
    doc_md=__doc__,
)
def cairo_air_quality_daily():
    @task
    def check_warehouse_ready() -> int:
        """Fail fast if the DDL was never applied.

        Without this, a fresh warehouse produces a foreign-key violation from
        deep inside the upsert -- technically correct, but the error names a
        constraint rather than the actual problem, which is that nobody ran
        sql/. One cheap query up front turns that into a sentence.
        """
        settings = Settings.from_env()
        conn = connect(settings)
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT count(*) FROM staging.pollutants")
                count = cur.fetchone()[0]
        finally:
            conn.close()

        if count == 0:
            raise RuntimeError(
                "staging.pollutants is empty -- the reference data was never "
                "loaded. Run ./scripts/apply_ddl.sh."
            )
        log.info("warehouse ready: %d pollutants registered", count)
        return count

    @task
    def ingest() -> dict:
        """Pull the window this run is responsible for and load it."""
        context = get_current_context()
        settings = Settings.from_env()

        # data_interval_end is the exclusive upper bound of the run's interval,
        # so for the run covering 2026-09-18 it is 2026-09-19T00:00. Taking its
        # date gives the last day we ask the API for.
        #
        # The final day of the window is usually incomplete -- the 03:00 run
        # asks for today and gets three hours of it. That is intentional: the
        # lookback window overlaps the previous six runs, so tomorrow's run
        # fills in the rest of today, and the upsert makes the overlap free.
        # Late-arriving and revised values get repaired the same way.
        #
        # A MANUALLY triggered run has no data interval in Airflow 3 -- only
        # scheduled runs and backfills get one -- so this key is genuinely
        # absent rather than merely empty, and indexing it raises KeyError.
        # "Run it now" is the obvious intent behind pressing the trigger
        # button, so fall back to the current UTC date.
        interval_end = context.get("data_interval_end")
        if interval_end is None:
            interval_end = pendulum.now("UTC")
            log.info("manual run with no data interval; using %s", interval_end.date())

        window_end = interval_end.date()
        window_start = window_end - timedelta(days=settings.lookback_days - 1)

        log.info(
            "run %s -> ingesting %s..%s",
            context["dag_run"].run_id, window_start, window_end,
        )

        summary = run_window(settings, window_start, window_end)

        log.info(
            "submitted=%d inserted=%d changed=%d unchanged=%d forecast_dropped=%d",
            summary.submitted, summary.inserted, summary.changed,
            summary.unchanged, summary.dropped_future,
        )
        # Returned values go to XCom, which is backed by the metadata database.
        # Small scalars only -- this is a summary for the UI, never the data.
        return summary._asdict()

    # Stage 4 appends the dbt tasks here:
    #     check_warehouse_ready() >> ingest() >> dbt_run >> dbt_test
    check_warehouse_ready() >> ingest()


cairo_air_quality_daily()
