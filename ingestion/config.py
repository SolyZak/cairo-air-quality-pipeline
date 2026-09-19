"""Configuration, read once from the environment.

Everything the pipeline needs to know that differs between machines lives here
and nowhere else. No module below this one reads os.environ, so there is a
single place to look when a setting is wrong.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import date, timedelta

# The Open-Meteo hourly variable names we request. These strings are used three
# ways -- as the API query parameter, as the key into the response's arrays, and
# as staging.hourly_readings.pollutant_code -- which is exactly why we keep the
# source system's spelling instead of inventing our own codes. No mapping table,
# nothing to keep in sync.
POLLUTANTS: tuple[str, ...] = ("pm2_5", "pm10", "nitrogen_dioxide", "ozone")


class ConfigError(RuntimeError):
    """A required setting is missing or unusable."""


def _require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ConfigError(
            f"environment variable {name} is not set. "
            f"Did you copy .env.example to .env?"
        )
    return value


@dataclass(frozen=True)
class Settings:
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str

    api_base_url: str
    location_code: str
    latitude: float
    longitude: float
    lookback_days: int

    @classmethod
    def from_env(cls) -> "Settings":
        try:
            return cls(
                # 'postgres' inside the compose network, 'localhost' from a
                # virtualenv on the host. See the note in .env.example.
                db_host=os.environ.get("POSTGRES_HOST", "postgres"),
                db_port=int(os.environ.get("POSTGRES_PORT", "5432")),
                db_name=_require("POSTGRES_DB"),
                db_user=_require("POSTGRES_USER"),
                db_password=_require("POSTGRES_PASSWORD"),
                api_base_url=_require("AQ_API_BASE_URL"),
                location_code=_require("AQ_LOCATION_CODE"),
                latitude=float(_require("AQ_LATITUDE")),
                longitude=float(_require("AQ_LONGITUDE")),
                lookback_days=int(os.environ.get("AQ_LOOKBACK_DAYS", "7")),
            )
        except ValueError as exc:  # int()/float() on a malformed value
            raise ConfigError(f"a numeric setting could not be parsed: {exc}") from exc

    def dsn(self) -> str:
        """libpq connection string. Kept out of logs -- it carries the password."""
        return (
            f"host={self.db_host} port={self.db_port} dbname={self.db_name} "
            f"user={self.db_user} password={self.db_password}"
        )


def default_window(lookback_days: int, today: date) -> tuple[date, date]:
    """The window a scheduled run pulls: `lookback_days` calendar days ending today.

    Inclusive of both ends, so lookback_days=7 means today and the six days
    before it -- seven dates, not eight.
    """
    if lookback_days < 1:
        raise ConfigError("lookback_days must be at least 1")
    return today - timedelta(days=lookback_days - 1), today
