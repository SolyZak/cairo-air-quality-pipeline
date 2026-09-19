"""Daily Cairo air quality ingestion.

Airflow orientation, since this is the first DAG in the project:

  * A DAG is a schedule plus a graph of tasks. This file is not "the pipeline" --
    the pipeline lives in the `ingestion` package. The DAG only decides WHEN to
    call it and WHAT date window to ask for. Keeping the work outside the DAG is
    what lets you run the exact same code from the CLI with no scheduler.

  * Every scheduled run carries a LOGICAL DATE and a DATA INTERVAL that belong
    to the RUN, not to the wall clock. Deriving the window from them -- rather
    than from today's date -- is the single thing that makes backfill work: a
    run for a date last month pulls last month's data, not this morning's.

    Careful here, because the semantics changed. In Airflow 2 a daily cron run
    covered a span: [2026-09-18T03:00, 2026-09-19T03:00). In Airflow 3 a
    NON-PARTITIONED dag like this one gets a ZERO-WIDTH interval instead --
    logical_date, data_interval_start and data_interval_end are all the same
    instant, the moment the cron fired. Confirmed against the metadata
    database rather than assumed:

        run_id                                run_after    interval_start/end
        scheduled__2026-09-19T03:00:00+00:00  09-19 03:00  09-19 03:00 (both)

    So data_interval_end.date() is simply the run's own date. That is all this
    DAG needs, and it behaves identically under either model -- but the older
    "end is the exclusive upper bound of a day-long span" mental model is
    wrong here, and would mislead anyone extending this file.

  * `catchup=False` means turning the DAG on does not immediately schedule every
    missed day since start_date. Backfills are run deliberately instead, with
    `airflow backfill create` (see the README).
"""

from __future__ import annotations

import logging
from datetime import timedelta

import pendulum
from airflow.providers.standard.operators.bash import BashOperator
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

# dbt runs from its own virtualenv -- see airflow.Dockerfile for why it is not
# installed alongside Airflow. The project directory is mounted read-only, so
# dbt's target/ and logs/ go to /tmp; nothing in them is worth keeping.
DBT_BIN = "/opt/dbt-venv/bin/dbt"
DBT_DIR = "/opt/airflow/dbt"
DBT_ENV = {
    "DBT_PROFILES_DIR": DBT_DIR,
    "DBT_TARGET_PATH": "/tmp/dbt-target",
    "DBT_LOG_PATH": "/tmp/dbt-logs",
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

        # data_interval_end is this run's own timestamp (see the module
        # docstring: the interval is zero-width for a non-partitioned dag in
        # Airflow 3), so its date is the last day we ask the API for.
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

    # `dbt run` and `dbt test` are separate tasks rather than a single
    # `dbt build`. build interleaves them, which is better at stopping bad data
    # reaching downstream models -- but with four models and no downstream
    # consumers, the clearer signal wins: the Airflow graph then distinguishes
    # "the models would not build" from "the models built and the data is
    # wrong", which are different pages of the runbook.
    #
    # append_env keeps the container's POSTGRES_* variables, which profiles.yml
    # reads; without it, env= would replace the environment wholesale.
    #
    # retries=1, not the DAG default of 4. A failing dbt test is deterministic
    # -- the same bad row fails the same way four times over half an hour, and
    # all that buys is a later alert. The single retry covers a genuinely
    # transient case, like the database restarting mid-run.
    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command=f"{DBT_BIN} run --project-dir {DBT_DIR}",
        env=DBT_ENV,
        append_env=True,
        retries=1,
    )

    dbt_test = BashOperator(
        task_id="dbt_test",
        bash_command=f"{DBT_BIN} test --project-dir {DBT_DIR}",
        env=DBT_ENV,
        append_env=True,
        retries=1,
    )

    check_warehouse_ready() >> ingest() >> dbt_run >> dbt_test


cairo_air_quality_daily()
