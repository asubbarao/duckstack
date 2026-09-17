-- Parse previously landed immutable Slack responses.
--
-- Run after outputs/sql/slack_messages.sql:
--   duckdb outputs/api_pipeline.duckdb < outputs/sql/parse_slack_raw.sql
--
-- This pipeline may be rerun as parsing rules evolve. It never rewrites raw
-- NDJSON objects.

.bail on

INSTALL webbed FROM community;
LOAD webbed;

CREATE OR REPLACE VIEW raw_api_responses AS
SELECT *
FROM read_json(
    'outputs/raw/slack/*.ndjson',
    format := 'newline_delimited',
    union_by_name := true,
    maximum_depth := -1,
    sample_size := -1,
    maximum_object_size := 67108864
);

CREATE OR REPLACE VIEW parsed_api_responses AS
WITH parsed AS (
    SELECT
        *,
        CASE
            WHEN body_format = 'json' THEN json_valid(body_raw)
        END AS body_json_valid,
        CASE
            WHEN body_format = 'json' THEN try_cast(body_raw AS JSON)
        END AS body
    FROM raw_api_responses
),
webbed AS (
    SELECT
        *,
        CASE
            WHEN body_format = 'json' AND body_json_valid
                THEN json_to_xml(body_raw)
            WHEN body_format = 'html'
                THEN to_xml(parse_html(body_raw))::VARCHAR
        END AS body_xml
    FROM parsed
)
SELECT
    *,
    xml_valid(body_xml) AS body_xml_valid,
    xml_to_json(body_xml)::JSON AS body_json_roundtrip
FROM webbed;

CREATE OR REPLACE VIEW slack_channels AS
SELECT
    source_id,
    fetched_at,
    request,
    http_response,
    body_xml_valid,
    unnest((body->'channels')::JSON[]) AS channel
FROM parsed_api_responses
WHERE resource = 'channels'
  AND body_json_valid;

CREATE OR REPLACE VIEW slack_messages AS
SELECT
    source_id,
    fetched_at,
    request,
    http_response,
    body_xml_valid,
    unnest((body->'messages')::JSON[]) AS message
FROM parsed_api_responses
WHERE resource = 'messages'
  AND body_json_valid;

CREATE OR REPLACE VIEW slack_api_failures AS
SELECT *
FROM parsed_api_responses
WHERE protocol = 'rest'
  AND (
      body_json_valid IS DISTINCT FROM true
      OR (body->>'ok') IS DISTINCT FROM 'true'
  );

DESCRIBE raw_api_responses;
DESCRIBE parsed_api_responses;
DESCRIBE slack_channels;
DESCRIBE slack_messages;
DESCRIBE slack_api_failures;
