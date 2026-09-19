# Standalone runner for the ingestion CLI.
#
# This exists because "runnable standalone" should not mean "first install
# Python 3.12 on your laptop". The image pins the interpreter so the script
# behaves identically on any machine, and `docker compose run --rm ingest`
# is the whole setup step.
FROM python:3.12-slim

# Unbuffered so log lines appear immediately in `docker compose run` and in
# Airflow's task logs, rather than being held until the process exits.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /opt/pipeline

# Copied and installed before the source, so editing a .py file does not
# invalidate the layer that pip installed into.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY ingestion ./ingestion

# Run as a non-root user. Nothing here needs root, and the container writes
# nothing to disk.
RUN useradd --create-home --uid 1000 pipeline
USER pipeline

ENTRYPOINT ["python", "-m", "ingestion"]
