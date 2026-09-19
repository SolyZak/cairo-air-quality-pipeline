"""Parsing and the four upstream guards.

These are the tests that matter most in this project. The guards exist because
a wrong-but-plausible number is far more damaging than a crash, and a guard
nobody tests is just a comment.

No network and no database: parse() is a pure function over a dict.
"""

from datetime import datetime, timezone

import pytest

from ingestion.open_meteo import (
    ApiResponse,
    UpstreamDataError,
    normalise_unit,
    parse,
)

POLLUTANTS = ("pm2_5", "pm10", "nitrogen_dioxide", "ozone")
EXPECTED_UNITS = {p: "ug/m3" for p in POLLUTANTS}

# Fixed "now" so the forecast-dropping tests never depend on the wall clock.
NOW = datetime(2026, 9, 19, 12, 0, tzinfo=timezone.utc)

GREEK_MU = "μg/m³"   # what Open-Meteo actually sends
MICRO_SIGN = "µg/m³"  # the visually identical impostor


def make_response(*, times=None, values=None, units=None, offset=0):
    times = times if times is not None else [
        "2026-09-19T10:00",   # past
        "2026-09-19T11:00",   # past
        "2026-09-19T23:00",   # future -- forecast
    ]
    values = values if values is not None else [1.0, None, 3.0]
    payload = {
        "utc_offset_seconds": offset,
        "hourly_units": units if units is not None else {p: GREEK_MU for p in POLLUTANTS},
        "hourly": {"time": times, **{p: list(values) for p in POLLUTANTS}},
    }
    return ApiResponse("https://example.invalid", {}, 200, payload, "0" * 64)


class TestNormaliseUnit:
    @pytest.mark.parametrize("raw", [GREEK_MU, MICRO_SIGN, "ug/m3"])
    def test_accepts_every_spelling_we_have_seen(self, raw):
        assert normalise_unit(raw) == "ug/m3"

    def test_greek_mu_and_micro_sign_are_genuinely_different_characters(self):
        # Guards against someone "tidying up" the alias table and deleting one.
        assert GREEK_MU != MICRO_SIGN
        assert normalise_unit(GREEK_MU) == normalise_unit(MICRO_SIGN)

    @pytest.mark.parametrize("raw", ["mg/m3", "ppb", "", "ug/m2"])
    def test_rejects_anything_else(self, raw):
        # A silent scale change is the worst failure mode available: every
        # number stays plausible and every number is wrong.
        with pytest.raises(UpstreamDataError):
            normalise_unit(raw)


class TestGuards:
    def test_rejects_a_non_utc_offset(self):
        with pytest.raises(UpstreamDataError, match="utc_offset_seconds"):
            parse(make_response(offset=7200), "cairo", EXPECTED_UNITS, NOW)

    def test_rejects_value_array_shorter_than_time_array(self):
        r = make_response(times=["2026-09-19T10:00", "2026-09-19T11:00"], values=[1.0])
        with pytest.raises(UpstreamDataError, match="hourly.time"):
            parse(r, "cairo", EXPECTED_UNITS, NOW)

    def test_rejects_a_missing_pollutant(self):
        r = make_response()
        del r.payload["hourly"]["ozone"]
        with pytest.raises(UpstreamDataError, match="ozone"):
            parse(r, "cairo", EXPECTED_UNITS, NOW)

    def test_rejects_a_unit_the_warehouse_does_not_expect(self):
        r = make_response()
        with pytest.raises(UpstreamDataError, match="pm2_5"):
            parse(r, "cairo", {**EXPECTED_UNITS, "pm2_5": "mg/m3"}, NOW)

    def test_rejects_an_empty_response(self):
        r = make_response(times=[])
        with pytest.raises(UpstreamDataError):
            parse(r, "cairo", EXPECTED_UNITS, NOW)


class TestParsing:
    def test_drops_forecast_hours_and_keeps_past_ones(self):
        readings, dropped = parse(make_response(), "cairo", EXPECTED_UNITS, NOW)
        # 3 hours x 4 pollutants, minus the one future hour x 4.
        assert dropped == 4
        assert len(readings) == 8
        assert all(r.measured_at_utc <= NOW for r in readings)

    def test_an_hour_exactly_equal_to_now_is_kept(self):
        # Boundary: `>` not `>=`, or the current hour would vanish every run.
        r = make_response(times=["2026-09-19T12:00"], values=[5.0])
        readings, dropped = parse(r, "cairo", EXPECTED_UNITS, NOW)
        assert dropped == 0
        assert len(readings) == 4

    def test_nulls_are_preserved_rather_than_dropped(self):
        readings, _ = parse(make_response(), "cairo", EXPECTED_UNITS, NOW)
        # A gap must stay countable; dropping the row would make the series
        # look complete when it is not.
        assert sum(1 for r in readings if r.value is None) == 4

    def test_timestamps_are_timezone_aware_utc(self):
        readings, _ = parse(make_response(), "cairo", EXPECTED_UNITS, NOW)
        assert all(r.measured_at_utc.tzinfo is not None for r in readings)
        assert all(r.measured_at_utc.utcoffset().total_seconds() == 0 for r in readings)

    def test_values_stay_aligned_with_their_timestamps(self):
        # The failure this guards against is silent: misaligned values still
        # look like perfectly reasonable readings.
        r = make_response(
            times=["2026-09-19T09:00", "2026-09-19T10:00", "2026-09-19T11:00"],
            values=[9.0, 10.0, 11.0],
        )
        readings, _ = parse(r, "cairo", EXPECTED_UNITS, NOW)
        for reading in readings:
            assert reading.value == float(reading.measured_at_utc.hour)

    def test_unit_is_normalised_on_every_reading(self):
        readings, _ = parse(make_response(), "cairo", EXPECTED_UNITS, NOW)
        assert {r.unit for r in readings} == {"ug/m3"}

    def test_location_code_is_stamped_on_every_reading(self):
        readings, _ = parse(make_response(), "alexandria", EXPECTED_UNITS, NOW)
        assert {r.location_code for r in readings} == {"alexandria"}

    def test_all_four_pollutants_are_produced(self):
        readings, _ = parse(make_response(), "cairo", EXPECTED_UNITS, NOW)
        assert {r.pollutant_code for r in readings} == set(POLLUTANTS)
