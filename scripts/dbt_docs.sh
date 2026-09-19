#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build and serve the dbt documentation site -- a browsable lineage graph of
# every model, column, description and test.
#
#   ./scripts/dbt_docs.sh        then open http://localhost:8081
#
# Ctrl-C to stop. --host 0.0.0.0 is required: dbt binds to localhost by
# default, which from inside a container means the container's own loopback
# and is unreachable from your machine.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/dbt.sh docs generate

echo
echo "Serving dbt docs on http://localhost:${DBT_DOCS_PORT:-8081}  (Ctrl-C to stop)"
echo

docker compose exec \
  -e DBT_PROFILES_DIR=/opt/airflow/dbt \
  -e DBT_TARGET_PATH=/tmp/dbt-target \
  -e DBT_LOG_PATH=/tmp/dbt-logs \
  airflow-scheduler /opt/dbt-venv/bin/dbt docs serve \
    --project-dir /opt/airflow/dbt --host 0.0.0.0 --port 8081
