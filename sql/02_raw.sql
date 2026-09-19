-- ---------------------------------------------------------------------------
-- raw.air_quality_responses
--
-- One row per HTTP call to Open-Meteo. Append-only: a re-run on the same day
-- inserts another row rather than replacing yesterday's. That is deliberate --
-- the raw layer is the audit trail. If the API silently changes a value, or we
-- discover a bug in the parser three weeks from now, the original bytes are
-- still here to replay.
--
-- Deduplication is the *staging* layer's job (see 03_staging.sql).
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.air_quality_responses (
    response_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Which API, so a second source can land in the same table later.
    source          text        NOT NULL DEFAULT 'open-meteo-air-quality',

    -- Exactly what we asked for. Stored separately from the payload because
    -- the response does not echo every parameter back, and "what did we
    -- request?" is the first question when numbers look wrong.
    request_url     text        NOT NULL,
    request_params  jsonb       NOT NULL,

    -- The date window requested (the API's start_date / end_date). Lets a
    -- backfill find and re-run a specific window without parsing the payload.
    window_start    date        NOT NULL,
    window_end      date        NOT NULL,

    http_status     smallint    NOT NULL,

    -- The response body. jsonb rather than text: we lose byte-for-byte
    -- fidelity (key order, whitespace, duplicate keys) but gain indexing and
    -- `->>` access, which matters far more for a body this well-behaved.
    -- payload_sha256 below is computed over the raw bytes BEFORE parsing, so
    -- the exact response is still identifiable even though it is not stored
    -- verbatim.
    payload         jsonb       NOT NULL,
    payload_sha256  char(64)    NOT NULL,

    -- Required by the brief. Wall-clock time the row landed, always UTC.
    ingested_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT air_quality_responses_window_ck CHECK (window_end >= window_start),
    CONSTRAINT air_quality_responses_status_ck CHECK (http_status BETWEEN 100 AND 599)
);

-- Staging reads "everything landed since my last load", so ingested_at is the
-- hot path. DESC because every practical query wants the newest first.
CREATE INDEX IF NOT EXISTS air_quality_responses_ingested_at_ix
    ON raw.air_quality_responses (ingested_at DESC);

-- Supports "find the response(s) covering 2026-09-14" during a backfill.
CREATE INDEX IF NOT EXISTS air_quality_responses_window_ix
    ON raw.air_quality_responses (window_start, window_end);

-- Not unique: an identical payload arriving twice is normal (the API is
-- stable, we poll daily with an overlapping window). The index just makes
-- "how much of what we pulled was new?" cheap to answer.
CREATE INDEX IF NOT EXISTS air_quality_responses_sha256_ix
    ON raw.air_quality_responses (payload_sha256);

COMMENT ON TABLE  raw.air_quality_responses               IS 'Append-only log of Open-Meteo Air Quality API responses. Never UPDATE or DELETE.';
COMMENT ON COLUMN raw.air_quality_responses.payload_sha256 IS 'SHA-256 of the raw response body as received, before JSON parsing.';
COMMENT ON COLUMN raw.air_quality_responses.ingested_at    IS 'UTC timestamp the row was written. Watermark source for the staging load.';
