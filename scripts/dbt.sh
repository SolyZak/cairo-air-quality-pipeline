#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run dbt inside the Airflow container, where it is installed.
#
#   ./scripts/dbt.sh run
#   ./scripts/dbt.sh test
#   ./scripts/dbt.sh build          # run + test, in dependency order
#   ./scripts/dbt.sh run --full-refresh
#
# dbt lives in its own virtualenv (/opt/dbt-venv) so its dependency tree never
# meets Airflow's -- see airflow.Dockerfile.
#
# The project directory is mounted READ-ONLY, so dbt's target/ and logs/ are
# redirected to /tmp inside the container. These are set as ENVIRONMENT
# VARIABLES rather than --target-path/--log-path flags because the flags are
# not accepted by every subcommand (dbt debug rejects --target-path), whereas
# the env vars apply uniformly. Nothing in target/ is worth keeping; the
# artefacts that matter are the tables dbt writes.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

exec docker compose exec -T \
  -e DBT_PROFILES_DIR=/opt/airflow/dbt \
  -e DBT_TARGET_PATH=/tmp/dbt-target \
  -e DBT_LOG_PATH=/tmp/dbt-logs \
  airflow-scheduler /opt/dbt-venv/bin/dbt "$@" --project-dir /opt/airflow/dbt
