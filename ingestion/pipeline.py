"""Orchestration: fetch -> land raw -> upsert staging, for one or more windows.

Airflow imports run_window() directly in stage 3. Keeping the work in a plain
function -- rather than inside the DAG file -- means it can be run, tested and
debugged with no scheduler involved.
"""

from __future__ import annotations

import logging
from datetime import date, timedelta
from typing import Iterator, NamedTuple

from .config import Settings
from .loader import connect, fetch_expected_units, insert_raw_response, upsert_readings
from .open_meteo import build_session, fetch, parse

log = logging.getLogger(__name__)


class RunSummary(NamedTuple):
    windows: int
    submitted: int
    inserted: int
    changed: int
    unchanged: int
    dropped_future: int


def iter_windows(start: date, end: date, chunk_days: int) -> Iterator[tuple[date, date]]:
    """Split an inclusive date range into chunks of at most `chunk_days`.

    A daily run is a single chunk, so this does nothing in the normal case. It
    exists for backfills: asking for a year in one request would produce one
    enormous JSON document in a single raw row, which is slow to insert, awkward
    to inspect, and all-or-nothing if it fails. Chunking gives one raw row per
    window and lets a long backfill fail partway without losing what succeeded.
    """
    if end < start:
        raise ValueError(f"end ({end}) is before start ({start})")
    if chunk_days < 1:
        raise ValueError("chunk_days must be at least 1")

    cursor = start
    while cursor <= end:
        chunk_end = min(cursor + timedelta(days=chunk_days - 1), end)
        yield cursor, chunk_end
        cursor = chunk_end + timedelta(days=1)


def run_window(
    settings: Settings,
    start: date,
    end: date,
    chunk_days: int = 31,
    dry_run: bool = False,
) -> RunSummary:
    """Ingest an inclusive date range. Safe to call repeatedly for the same range."""
    session = build_session()

    totals = dict(windows=0, submitted=0, inserted=0, changed=0, unchanged=0, dropped=0)

    conn = None if dry_run else connect(settings)
    try:
        # Read the expected units once per run, not once per window.
        expected_units = {} if dry_run else fetch_expected_units(conn)
        if dry_run:
            log.warning("dry run: nothing will be written, unit checks are skipped")

        for window_start, window_end in iter_windows(start, end, chunk_days):
            response = fetch(settings, window_start, window_end, session)
            readings, dropped = parse(
                response, settings.location_code, expected_units
            )

            log.info(
                "parsed %d readings (%d forecast hours dropped) for %s..%s",
                len(readings),
                dropped,
                window_start,
                window_end,
            )

            totals["windows"] += 1
            totals["dropped"] += dropped

            if dry_run:
                totals["submitted"] += len(readings)
                continue

            response_id = insert_raw_response(conn, response, window_start, window_end)
            result = upsert_readings(conn, readings, response_id)

            totals["submitted"] += result.submitted
            totals["inserted"] += result.inserted
            totals["changed"] += result.changed
            totals["unchanged"] += result.unchanged
    finally:
        session.close()
        if conn is not None:
            conn.close()

    return RunSummary(
        windows=totals["windows"],
        submitted=totals["submitted"],
        inserted=totals["inserted"],
        changed=totals["changed"],
        unchanged=totals["unchanged"],
        dropped_future=totals["dropped"],
    )
