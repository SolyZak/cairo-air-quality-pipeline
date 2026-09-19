"""Database side: land the raw response, then upsert readings into staging."""

from __future__ import annotations

import json
import logging
from datetime import date
from typing import Iterable, NamedTuple

import psycopg2
import psycopg2.extras

from .config import Settings
from .open_meteo import ApiResponse, Reading

log = logging.getLogger(__name__)


class UpsertResult(NamedTuple):
    submitted: int
    inserted: int
    changed: int

    @property
    def unchanged(self) -> int:
        """Rows already present with the same value.

        On a healthy daily run with a 7-day window this is the large majority --
        which is the idempotency of the load, visible as a number.
        """
        return self.submitted - self.inserted - self.changed


def connect(settings: Settings):
    conn = psycopg2.connect(settings.dsn())
    # Explicit: we manage transactions ourselves (see the two commits below).
    conn.autocommit = False
    return conn


def fetch_expected_units(conn) -> dict[str, str]:
    """The unit each pollutant is supposed to arrive in.

    Read from staging.pollutants rather than hardcoded, so the reference table
    stays the single source of truth for the domain.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT pollutant_code, unit FROM staging.pollutants")
        return dict(cur.fetchall())


def insert_raw_response(
    conn, response: ApiResponse, window_start: date, window_end: date
) -> int:
    """Append the response to raw and COMMIT immediately.

    The commit is deliberately separate from the staging load below. If parsing
    or upserting fails, the raw payload must still be on disk -- a response that
    breaks the parser is precisely the one worth keeping. Wrapping both in one
    transaction would roll back the evidence along with the failure.

    The cost is that a failed run can leave a raw row with no staging rows.
    That is a feature: it is a queue of payloads to investigate.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.air_quality_responses
                (request_url, request_params, window_start, window_end,
                 http_status, payload, payload_sha256)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            RETURNING response_id
            """,
            (
                response.url,
                json.dumps(response.params),
                window_start,
                window_end,
                response.status_code,
                json.dumps(response.payload),
                response.sha256,
            ),
        )
        response_id = cur.fetchone()[0]
    conn.commit()
    log.info("raw.air_quality_responses <- response_id=%s", response_id)
    return response_id


def upsert_readings(
    conn, readings: Iterable[Reading], source_response_id: int
) -> UpsertResult:
    """Idempotent load into staging.hourly_readings.

    The whole idempotency story is the ON CONFLICT clause. The primary key is
    the natural key of a measurement, so re-running a window cannot duplicate a
    row -- the second attempt collides and updates instead.

    Two details worth knowing:

      * `WHERE ... IS DISTINCT FROM` makes an unchanged row a genuine no-op:
        no write, no dead tuple, and loaded_at keeps meaning "when this value
        last CHANGED" rather than "when we last looked at it". IS DISTINCT FROM
        rather than <> because value is nullable, and NULL <> NULL is NULL, not
        true -- a plain <> would rewrite every null row on every run.

      * `RETURNING (xmax = 0)` distinguishes inserts from updates. xmax holds
        the id of the transaction that superseded a row version; it is zero for
        a freshly inserted tuple and non-zero for one produced by an UPDATE.
        It is an implementation detail rather than documented API, but it is
        the standard way to get this out of a single statement, and here it
        only drives a log line -- nothing depends on it being right.
    """
    rows = [
        (
            r.location_code,
            r.pollutant_code,
            r.measured_at_utc,
            r.value,
            r.unit,
            source_response_id,
        )
        for r in readings
    ]
    if not rows:
        return UpsertResult(0, 0, 0)

    with conn.cursor() as cur:
        returned = psycopg2.extras.execute_values(
            cur,
            """
            INSERT INTO staging.hourly_readings
                (location_code, pollutant_code, measured_at_utc,
                 value, unit, source_response_id)
            VALUES %s
            ON CONFLICT (location_code, pollutant_code, measured_at_utc)
            DO UPDATE SET
                value              = EXCLUDED.value,
                unit               = EXCLUDED.unit,
                source_response_id = EXCLUDED.source_response_id,
                loaded_at          = now()
            WHERE staging.hourly_readings.value IS DISTINCT FROM EXCLUDED.value
               OR staging.hourly_readings.unit  IS DISTINCT FROM EXCLUDED.unit
            RETURNING (xmax = 0) AS was_insert
            """,
            rows,
            page_size=1000,
            fetch=True,
        )
    conn.commit()

    inserted = sum(1 for (was_insert,) in returned if was_insert)
    changed = len(returned) - inserted
    result = UpsertResult(submitted=len(rows), inserted=inserted, changed=changed)
    log.info(
        "staging.hourly_readings <- submitted=%d inserted=%d changed=%d unchanged=%d",
        result.submitted,
        result.inserted,
        result.changed,
        result.unchanged,
    )
    return result
