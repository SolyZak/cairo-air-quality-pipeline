#!/usr/bin/env bash
# Open a psql shell on the warehouse database.
#   ./scripts/psql.sh                    -- interactive
#   ./scripts/psql.sh -c '\dt staging.*' -- one-shot
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
set -a; source .env; set +a
exec docker compose exec postgres \
  psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
