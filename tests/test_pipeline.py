"""Date-window chunking.

Chunking is arithmetic, and arithmetic over date ranges is where off-by-one
errors live. A gap here means a silently missing day; an overlap means wasted
API calls. Both are cheap to test and expensive to notice in production.
"""

from datetime import date, timedelta

import pytest

from ingestion.pipeline import iter_windows


def windows(start, end, chunk):
    return list(iter_windows(date.fromisoformat(start), date.fromisoformat(end), chunk))


class TestIterWindows:
    def test_a_short_range_is_a_single_window(self):
        assert windows("2026-09-13", "2026-09-19", 31) == [
            (date(2026, 9, 13), date(2026, 9, 19))
        ]

    def test_a_single_day_is_one_window_of_one_day(self):
        assert windows("2026-09-19", "2026-09-19", 31) == [
            (date(2026, 9, 19), date(2026, 9, 19))
        ]

    def test_a_long_range_is_split(self):
        assert windows("2026-08-01", "2026-09-09", 31) == [
            (date(2026, 8, 1), date(2026, 8, 31)),
            (date(2026, 9, 1), date(2026, 9, 9)),
        ]

    def test_a_range_that_divides_exactly_produces_no_empty_tail(self):
        result = windows("2026-08-01", "2026-08-10", 5)
        assert result == [
            (date(2026, 8, 1), date(2026, 8, 5)),
            (date(2026, 8, 6), date(2026, 8, 10)),
        ]

    @pytest.mark.parametrize("chunk", [1, 2, 3, 7, 31, 400])
    def test_windows_are_contiguous_and_cover_the_range_exactly(self, chunk):
        start, end = date(2026, 1, 1), date(2026, 4, 15)
        result = list(iter_windows(start, end, chunk))

        # Covers the ends...
        assert result[0][0] == start
        assert result[-1][1] == end
        # ...with no gap and no overlap between consecutive windows...
        for (_, prev_end), (next_start, _) in zip(result, result[1:]):
            assert next_start == prev_end + timedelta(days=1)
        # ...and every window within the size limit.
        assert all((w_end - w_start).days + 1 <= chunk for w_start, w_end in result)

    @pytest.mark.parametrize("chunk", [1, 7, 31])
    def test_every_date_appears_exactly_once(self, chunk):
        start, end = date(2026, 1, 1), date(2026, 2, 20)
        seen = [
            w_start + timedelta(days=i)
            for w_start, w_end in iter_windows(start, end, chunk)
            for i in range((w_end - w_start).days + 1)
        ]
        expected = [start + timedelta(days=i) for i in range((end - start).days + 1)]
        assert seen == expected

    def test_a_leap_day_is_not_skipped(self):
        result = windows("2028-02-27", "2028-03-02", 2)
        covered = {
            w_start + timedelta(days=i)
            for w_start, w_end in result
            for i in range((w_end - w_start).days + 1)
        }
        assert date(2028, 2, 29) in covered

    def test_rejects_a_backwards_range(self):
        with pytest.raises(ValueError):
            windows("2026-09-19", "2026-09-01", 31)

    @pytest.mark.parametrize("chunk", [0, -1])
    def test_rejects_a_non_positive_chunk_size(self, chunk):
        with pytest.raises(ValueError):
            windows("2026-09-01", "2026-09-19", chunk)
