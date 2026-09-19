"""Settings loading and the scheduled-window arithmetic."""

from datetime import date

import pytest

from ingestion.config import ConfigError, Settings, default_window

REQUIRED = {
    "POSTGRES_DB": "airquality",
    "POSTGRES_USER": "airquality",
    "POSTGRES_PASSWORD": "secret",
    "AQ_API_BASE_URL": "https://example.invalid/air-quality",
    "AQ_LOCATION_CODE": "cairo",
    "AQ_LATITUDE": "30.0444",
    "AQ_LONGITUDE": "31.2357",
}


def _set_env(monkeypatch, **overrides):
    env = {**REQUIRED, **overrides}
    for key in list(REQUIRED) + ["POSTGRES_HOST", "POSTGRES_PORT", "AQ_LOOKBACK_DAYS"]:
        monkeypatch.delenv(key, raising=False)
    for key, value in env.items():
        if value is not None:
            monkeypatch.setenv(key, value)


class TestDefaultWindow:
    def test_seven_days_means_seven_dates_inclusive(self):
        start, end = default_window(7, date(2026, 9, 19))
        assert (start, end) == (date(2026, 9, 13), date(2026, 9, 19))
        # The off-by-one that matters: inclusive on both ends.
        assert (end - start).days + 1 == 7

    def test_one_day_is_just_today(self):
        assert default_window(1, date(2026, 9, 19)) == (date(2026, 9, 19),) * 2

    def test_window_crosses_a_month_boundary(self):
        start, end = default_window(7, date(2026, 3, 3))
        assert start == date(2026, 2, 25)

    @pytest.mark.parametrize("days", [0, -1])
    def test_rejects_non_positive_lookback(self, days):
        with pytest.raises(ConfigError):
            default_window(days, date(2026, 9, 19))


class TestSettings:
    def test_reads_a_complete_environment(self, monkeypatch):
        _set_env(monkeypatch)
        s = Settings.from_env()
        assert s.location_code == "cairo"
        assert s.latitude == pytest.approx(30.0444)
        # Defaults apply where the variable is absent.
        assert s.db_host == "postgres"
        assert s.db_port == 5432
        assert s.lookback_days == 7

    @pytest.mark.parametrize("missing", sorted(REQUIRED))
    def test_every_required_variable_is_actually_required(self, monkeypatch, missing):
        _set_env(monkeypatch, **{missing: None})
        with pytest.raises(ConfigError) as exc:
            Settings.from_env()
        # The message has to name the variable -- a generic "config error" sends
        # you reading source code instead of editing .env.
        assert missing in str(exc.value)

    def test_blank_is_treated_as_missing(self, monkeypatch):
        # Compose substitutes an empty string for an unset variable rather than
        # omitting it, so "" has to fail the same way absent does.
        _set_env(monkeypatch, POSTGRES_DB="")
        with pytest.raises(ConfigError):
            Settings.from_env()

    def test_unparseable_number_is_a_config_error_not_a_valueerror(self, monkeypatch):
        _set_env(monkeypatch, AQ_LATITUDE="not-a-number")
        with pytest.raises(ConfigError):
            Settings.from_env()

    def test_dsn_contains_the_connection_fields(self, monkeypatch):
        _set_env(monkeypatch)
        dsn = Settings.from_env().dsn()
        for fragment in ("host=postgres", "port=5432", "dbname=airquality",
                         "user=airquality", "password=secret"):
            assert fragment in dsn
