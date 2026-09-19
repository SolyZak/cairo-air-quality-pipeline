"""CLI entry point:  python -m ingestion [options]

    python -m ingestion                                 # last AQ_LOOKBACK_DAYS days
    python -m ingestion --days 14
    python -m ingestion --start 2026-08-01 --end 2026-08-31
    python -m ingestion --dry-run                       # fetch and parse, write nothing

Exit codes: 0 success, 1 failure. Airflow, and any other scheduler, only needs
the exit code -- which is why the interesting detail goes to the log rather
than into a return value nobody reads.
"""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import date, datetime, timezone

from .config import ConfigError, Settings, default_window
from .open_meteo import UpstreamDataError
from .pipeline import run_window

log = logging.getLogger("ingestion")


def _valid_date(text: str) -> date:
    try:
        return datetime.strptime(text, "%Y-%m-%d").date()
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"{text!r} is not a date in YYYY-MM-DD form"
        ) from None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m ingestion",
        description="Ingest Cairo air quality from Open-Meteo into Postgres.",
    )

    # --days and --start/--end are alternative ways to say the same thing, so
    # accepting both at once would be ambiguous rather than merely redundant.
    window = parser.add_mutually_exclusive_group()
    window.add_argument(
        "--days",
        type=int,
        metavar="N",
        help="pull the last N days ending today (default: AQ_LOOKBACK_DAYS)",
    )
    window.add_argument(
        "--start", type=_valid_date, metavar="YYYY-MM-DD",
        help="first date to pull, inclusive. Requires --end.",
    )
    parser.add_argument(
        "--end", type=_valid_date, metavar="YYYY-MM-DD",
        help="last date to pull, inclusive. Requires --start.",
    )
    parser.add_argument(
        "--chunk-days", type=int, default=31, metavar="N",
        help="split long ranges into windows of at most N days (default: 31)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="fetch and parse but write nothing; needs no database",
    )
    parser.add_argument(
        "--log-level", default="INFO",
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
    )
    return parser


def resolve_window(args: argparse.Namespace, settings: Settings) -> tuple[date, date]:
    if args.start or args.end:
        if not (args.start and args.end):
            raise SystemExit("--start and --end must be given together")
        return args.start, args.end

    days = args.days if args.days is not None else settings.lookback_days
    # "Today" in UTC, matching the timezone the readings are stored in. Using
    # the machine's local date would shift the window by a day for anyone east
    # of Greenwich -- including, pointedly, Cairo.
    return default_window(days, datetime.now(timezone.utc).date())


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )

    try:
        settings = Settings.from_env()
        start, end = resolve_window(args, settings)

        log.info(
            "ingesting %s (%.4f, %.4f) for %s..%s",
            settings.location_code, settings.latitude, settings.longitude, start, end,
        )

        summary = run_window(
            settings, start, end,
            chunk_days=args.chunk_days,
            dry_run=args.dry_run,
        )

        log.info(
            "done: %d window(s), %d readings submitted "
            "(%d new, %d changed, %d unchanged), %d forecast readings dropped",
            summary.windows, summary.submitted, summary.inserted,
            summary.changed, summary.unchanged, summary.dropped_future,
        )
        return 0

    except ConfigError as exc:
        log.error("configuration problem: %s", exc)
        return 1
    except UpstreamDataError as exc:
        # The API gave us something we do not understand. Loading it anyway
        # would put bad numbers in the warehouse, which is worse than no
        # numbers -- so this is a hard failure, not a warning.
        log.error("refusing to load: %s", exc)
        return 1
    except Exception:
        log.exception("ingestion failed")
        return 1


if __name__ == "__main__":
    sys.exit(main())
