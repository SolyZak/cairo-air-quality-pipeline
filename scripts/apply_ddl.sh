#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Re-apply sql/ to an ALREADY RUNNING database.
#
# Why this exists: the files in sql/ are mounted into Postgres'
# /docker-entrypoint-initdb.d, which the official image runs exactly once --
# when the data volume is empty. Editing a DDL file after that first boot has
# no effect until you destroy the volume, which is a miserable way to iterate.
#
# Every statement in sql/ is written to be idempotent (IF NOT EXISTS,
# ON CONFLICT DO UPDATE), so this script is safe to run repeatedly.
#
#   ./scripts/apply_ddl.sh
#
# Note: it is NOT a migration tool. It cannot drop a column or change a type.
# For a project this size that is the right trade -- see README.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "error: .env not found. Run: cp .env.example .env" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

SERVICE=postgres

if ! docker compose ps --status running --services | grep -qx "$SERVICE"; then
  echo "error: the '$SERVICE' service is not running. Run: docker compose up -d" >&2
  exit 1
fi

for f in sql/*; do
  case "$f" in
    *.sh)
      echo "--> $f"
      # -T: no TTY, so this works unchanged in CI.
      docker compose exec -T "$SERVICE" bash -s < "$f"
      ;;
    *.sql)
      echo "--> $f"
      docker compose exec -T "$SERVICE" \
        psql -v ON_ERROR_STOP=1 --quiet \
             --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" < "$f"
      ;;
  esac
done

echo "DDL applied to database '$POSTGRES_DB'."
