#!/bin/bash
# ---------------------------------------------------------------------------
# Creates Airflow's metadata database next to the warehouse database.
#
# This is a .sh rather than a .sql file for one reason: files in
# /docker-entrypoint-initdb.d that end in .sql are fed straight to psql and
# cannot read environment variables, so the database name would have to be
# hardcoded. A shell script can interpolate ${AIRFLOW_DB} from .env.
#
# Airflow's metadata (DAG runs, task instances, connections) is operational
# state, not analytics data. Keeping it in its own database means a
# `DROP SCHEMA analytics CASCADE` can never take the scheduler down with it.
# ---------------------------------------------------------------------------
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
	-- CREATE DATABASE has no IF NOT EXISTS, so generate the statement only
	-- when the database is absent and let psql's \gexec run the result.
	-- This keeps the script safe to re-run against a live cluster.
	SELECT 'CREATE DATABASE $AIRFLOW_DB'
	WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$AIRFLOW_DB')\gexec
SQL

echo "[init] airflow metadata database '$AIRFLOW_DB' is present"
