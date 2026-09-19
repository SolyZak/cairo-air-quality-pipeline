"""Open-Meteo Air Quality client: fetch a date window, parse it into readings.

This module never touches the database. It turns HTTP into plain Python values
so it can be tested without Postgres running.
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import NamedTuple

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from .config import POLLUTANTS, Settings

log = logging.getLogger(__name__)

# The API reports concentrations as 'μg/m³'. That first character is GREEK
# SMALL LETTER MU (U+03BC), NOT the visually identical MICRO SIGN (U+00B5) --
# a naive `unit == "ug/m3"` comparison fails, and so does a comparison against
# the wrong mu. Both spellings are mapped here so either survives an upstream
# change of mind.
#
# This matters more than it looks. If Open-Meteo ever switched to mg/m³, every
# number would silently become 1000x wrong and nothing downstream would notice.
# Normalising and then *asserting* the unit is the cheap insurance.
_UNIT_ALIASES = {
    "μg/m³": "ug/m3",  # GREEK SMALL LETTER MU
    "µg/m³": "ug/m3",  # MICRO SIGN
    "ug/m3": "ug/m3",
}


class UpstreamDataError(RuntimeError):
    """The response parsed as JSON but does not mean what we assumed."""


def normalise_unit(raw: str) -> str:
    try:
        return _UNIT_ALIASES[raw]
    except KeyError:
        raise UpstreamDataError(
            f"unrecognised unit {raw!r} from the API. Refusing to load: an "
            f"unexpected unit usually means the scale changed."
        ) from None


class Reading(NamedTuple):
    """One measurement: the grain of staging.hourly_readings."""

    location_code: str
    pollutant_code: str
    measured_at_utc: datetime
    value: float | None
    unit: str


@dataclass(frozen=True)
class ApiResponse:
    url: str
    params: dict
    status_code: int
    payload: dict
    sha256: str


def build_session(total_retries: int = 3, backoff_factor: float = 1.0) -> requests.Session:
    """An HTTP session that retries transient failures.

    There are deliberately TWO layers of retry in this pipeline:

      * here, seconds apart, for a blip -- a dropped connection, a 502 from a
        load balancer, a rate limit. Retrying immediately is almost always
        right and costs nothing.
      * in Airflow, minutes apart, for an outage -- the API is down, the
        database is restarting. Those need time to heal, and burning a whole
        task run on them would be wasteful.

    Collapsing both into one layer means either hammering a dead service or
    failing a task over a hiccup.
    """
    retry = Retry(
        total=total_retries,
        backoff_factor=backoff_factor,  # sleeps 0s, 2s, 4s between attempts
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset(["GET"]),
        raise_on_status=False,
    )
    session = requests.Session()
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


def fetch(
    settings: Settings,
    start: date,
    end: date,
    session: requests.Session,
    timeout: float = 30.0,
) -> ApiResponse:
    """GET one date window. start and end are both inclusive."""
    params = {
        "latitude": settings.latitude,
        "longitude": settings.longitude,
        "hourly": ",".join(POLLUTANTS),
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        # Ask for UTC explicitly. The response is checked below to confirm the
        # API honoured it -- see the utc_offset_seconds guard in parse().
        "timezone": "UTC",
    }

    log.info("GET %s  window=%s..%s", settings.api_base_url, start, end)
    response = session.get(settings.api_base_url, params=params, timeout=timeout)

    # Hash the bytes as received, before any parsing, so the digest identifies
    # the exact response even though we store it as jsonb.
    digest = hashlib.sha256(response.content).hexdigest()

    # raise_for_status() after hashing: we want the digest even for a failure.
    response.raise_for_status()

    return ApiResponse(
        url=response.url,
        params=params,
        status_code=response.status_code,
        payload=response.json(),
        sha256=digest,
    )


def parse(
    response: ApiResponse,
    location_code: str,
    expected_units: dict[str, str],
    now_utc: datetime | None = None,
) -> tuple[list[Reading], int]:
    """Turn a response into readings.

    Returns (readings, dropped_future_hours).
    """
    now_utc = now_utc or datetime.now(timezone.utc)
    payload = response.payload

    # --- Guard 1: did we actually get UTC? ------------------------------------
    # If a future edit sets timezone=Africa/Cairo, every timestamp below would
    # be silently shifted by 2-3 hours and land under the wrong primary key.
    # Fail loudly instead.
    offset = payload.get("utc_offset_seconds")
    if offset != 0:
        raise UpstreamDataError(
            f"expected utc_offset_seconds=0, got {offset!r}. "
            f"Timestamps would be misattributed."
        )

    hourly = payload.get("hourly") or {}
    times = hourly.get("time")
    if not times:
        raise UpstreamDataError("response contains no hourly.time array")

    units = payload.get("hourly_units") or {}

    readings: list[Reading] = []
    dropped_future = 0

    for pollutant in POLLUTANTS:
        values = hourly.get(pollutant)
        if values is None:
            raise UpstreamDataError(f"response is missing hourly.{pollutant}")

        # --- Guard 2: arrays must line up with the time axis ------------------
        # Zipping mismatched lists would quietly truncate or misalign values
        # against timestamps -- the worst kind of bug, because the numbers still
        # look plausible.
        if len(values) != len(times):
            raise UpstreamDataError(
                f"hourly.{pollutant} has {len(values)} values but "
                f"hourly.time has {len(times)}"
            )

        # --- Guard 3: the unit is what the warehouse expects ------------------
        unit = normalise_unit(units.get(pollutant, ""))
        expected = expected_units.get(pollutant)
        if expected is not None and unit != expected:
            raise UpstreamDataError(
                f"{pollutant} arrived as {unit!r} but staging.pollutants "
                f"expects {expected!r}"
            )

        for raw_time, value in zip(times, values):
            # "2026-09-12T00:00" -- naive in the payload, but Guard 1 has
            # established it means UTC, so we attach the tzinfo here. Doing it
            # at the boundary means nothing downstream handles a naive datetime.
            measured_at = datetime.strptime(raw_time, "%Y-%m-%dT%H:%M").replace(
                tzinfo=timezone.utc
            )

            # --- Guard 4: drop forecast hours ---------------------------------
            # Open-Meteo returns the REST OF TODAY as forecast. A 7-day request
            # made at 11:34 UTC came back with 12 hours of predictions attached.
            # staging.hourly_readings is a table of measurements; writing a
            # forecast into it would corrupt every average computed downstream
            # and make the freshness test pass on data that does not exist yet.
            if measured_at > now_utc:
                dropped_future += 1
                continue

            readings.append(
                Reading(
                    location_code=location_code,
                    pollutant_code=pollutant,
                    measured_at_utc=measured_at,
                    # null in the payload = the API has no data for that hour.
                    # Kept as NULL rather than dropped, so the gap stays visible.
                    value=value,
                    unit=unit,
                )
            )

    return readings, dropped_future
