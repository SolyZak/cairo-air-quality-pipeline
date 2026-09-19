# Airflow image with the ingestion package's dependencies, plus dbt.
#
# ---------------------------------------------------------------------------
# Why dbt is installed into its OWN virtualenv
# ---------------------------------------------------------------------------
# Airflow and dbt both pin Jinja2, and historically they pin it to versions
# that cannot be satisfied at the same time. Installing dbt into the Airflow
# environment therefore either fails to resolve or silently downgrades one of
# Airflow's own dependencies -- a classic way to end up with a scheduler that
# boots but misbehaves.
#
# Giving dbt a separate venv means the two dependency trees never meet. The DAG
# calls /opt/dbt-venv/bin/dbt through a BashOperator, which is a subprocess with
# its own interpreter. This is the approach the dbt and Airflow docs both
# recommend, and it costs about 15 lines.
# ---------------------------------------------------------------------------
FROM apache/airflow:3.3.2

# --- the ingestion package's runtime deps, in Airflow's own environment ------
# These go in Airflow's environment (not a venv) because the DAG imports
# ingestion.pipeline directly, in-process. requests and psycopg2 are ordinary
# libraries with no version opinions that clash with Airflow's.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# --- dbt, isolated -----------------------------------------------------------
# --system-site-packages is deliberately NOT used: the point is isolation.
USER root
RUN python -m venv /opt/dbt-venv \
 && /opt/dbt-venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/dbt-venv/bin/pip install --no-cache-dir "dbt-postgres==1.11.0" \
 && chown -R airflow:root /opt/dbt-venv
USER airflow

# Handy for `docker compose exec`; the DAG uses the absolute path regardless,
# so nothing depends on this being on PATH.
ENV DBT_BIN=/opt/dbt-venv/bin/dbt
