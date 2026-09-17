-- duckdb :memory: -init outputs/sql/slack_messages.sql
-- SELECT * FROM slack_raw_responses; fetches; defining the view does not.
-- Persist each response, including API failures, before validating the run.
-- Parse landed data separately with parse_slack_raw.sql.
.bail on
INSTALL http_client FROM community;
INSTALL tera FROM community;
LOAD http_client;
LOAD tera;
.read outputs/sql/interval.sql

CREATE OR REPLACE VIEW slack_raw_responses AS
WITH RECURSIVE
source AS (
    SELECT struct_insert(config,
        window_start := (SELECT window_start FROM ingestion_interval),
        window_end := (SELECT window_end FROM ingestion_interval),
        target_url := nullif(getenv('SLACK_URL'), '')
    ) AS settings
    FROM read_json('outputs/sql/sources/slack.json') AS config
),
pages(settings, request, url, http_response, page_number) USING KEY (request, url) AS (
    SELECT settings,
        struct_pack(
            operation := CASE WHEN settings.target_url IS NULL THEN settings.channels_operation
                ELSE 'conversations.replies' END,
            resource := CASE WHEN settings.target_url IS NULL THEN 'channels' ELSE 'messages' END,
            params := CASE WHEN settings.target_url IS NULL THEN MAP {
                'types': settings.channel_types,
                'exclude_archived': 'false',
                'limit': settings.channel_page_size::VARCHAR
            } ELSE MAP {
                'channel': split_part(settings.target_url, '/', 5),
                'ts': substring(split_part(split_part(settings.target_url, '/', 6), '?', 1), 2, 10)
                    || '.' || substring(split_part(split_part(settings.target_url, '/', 6), '?', 1), 12),
                'limit': settings.history_page_size::VARCHAR
            } END
        ), NULL::VARCHAR, NULL::JSON, 0::BIGINT
    FROM source

    UNION

    SELECT pages.settings, next.request, endpoint.url,
        http_get(endpoint.url,
            MAP {
                'accept': 'application/json',
                'authorization': pages.settings.auth_scheme || ' ' || coalesce(
                    nullif(getenv(pages.settings.auth_env), ''),
                    error('Missing credential: ' || pages.settings.auth_env)
                )
            },
            next.request.params
        )::JSON, pages.page_number + 1
    FROM pages,
    LATERAL (SELECT try_cast(pages.http_response->>'body' AS JSON) AS body) AS decoded,
    LATERAL (
        -- The initial request and cursor pages share the same request shape.
        SELECT struct_update(pages.request,
            params := CASE WHEN cursor IS NULL THEN pages.request.params
                ELSE map_concat(pages.request.params, MAP {'cursor': cursor}) END
        ) AS request
        FROM (SELECT
            (decoded.body->>'ok') = 'true' AS api_ok,
            decoded.body->'response_metadata'->>'next_cursor' AS cursor
        )
        -- Retain the response row; only successful pages can seed another request.
        WHERE pages.http_response IS NULL
           OR (coalesce(api_ok, false) AND nullif(cursor, '') IS NOT NULL)

        UNION ALL

        -- Discovered, selected channels seed history requests.
        SELECT struct_pack(
            operation := pages.settings.history_operation,
            resource := 'messages',
            params := MAP {
                'channel': channel->>'id',
                'limit': pages.settings.history_page_size::VARCHAR,
                'include_all_metadata': 'true',
                'oldest': (epoch(pages.settings.window_start) - 0.000001)::DECIMAL(20,6)::VARCHAR,
                'latest': epoch(pages.settings.window_end)::DECIMAL(20,6)::VARCHAR
            }
        )
        FROM (SELECT unnest((decoded.body->'channels')::JSON[]) AS channel)
        WHERE pages.request.resource = 'channels'
          AND (decoded.body->>'ok') = 'true'
          AND list_contains(pages.settings.channel_ids, channel->>'id')
    ) AS next,
    LATERAL (
        SELECT tera_render('tera_rest.tera', json_object(
            'base_url', pages.settings.base_url,
            'operation', next.request.operation
        ), template_path := 'outputs/sql/templates/*.tera',
           autoescape := false) AS url
    ) AS endpoint
    WHERE NOT EXISTS (
        SELECT 1 FROM recurring.pages AS visited
        WHERE visited.url = endpoint.url AND visited.request = next.request
    )
)
SELECT settings.source_id, settings.protocol, request.resource,
    settings.window_start, settings.window_end,
    current_timestamp AS fetched_at,
    struct_insert(request, url := url) AS request,
    page_number, http_response, 'json' AS body_format,
    http_response->>'body' AS body_raw
FROM pages
WHERE http_response IS NOT NULL;

SET VARIABLE slack_raw_path = coalesce(nullif(getenv('SLACK_RAW_DIRECTORY'), ''),
    'outputs/raw/slack') || '/slack_' || uuid()::VARCHAR || '.ndjson';
COPY (SELECT * FROM slack_raw_responses)
TO (getvariable('slack_raw_path')) (FORMAT json, ARRAY false);

-- Read the saved file, never rescan the HTTP view to check a run.
WITH saved AS (
    SELECT *, try_cast(body_raw AS JSON) AS body, to_json(request) AS request_json,
        nullif(body->'response_metadata'->>'next_cursor', '') AS next_cursor
    FROM read_json(getvariable('slack_raw_path'), format := 'newline_delimited')
), validated AS (
    SELECT *, saved.next_cursor IS NULL OR EXISTS (
            SELECT 1 FROM saved AS successor
            WHERE successor.page_number > saved.page_number
              AND (successor.request_json->>'url') = (saved.request_json->>'url')
              AND (successor.request_json->'params'->>'channel')
                  IS NOT DISTINCT FROM (saved.request_json->'params'->>'channel')
              AND (successor.request_json->'params'->>'cursor') = saved.next_cursor
        ) AS cursor_completed
    FROM saved
)
SELECT CASE
    WHEN count(*) = 0 THEN error('Slack returned no response records')
    WHEN bool_and((http_response->>'status')::INTEGER BETWEEN 200 AND 299
        AND coalesce((body->>'ok') = 'true', false) AND cursor_completed)
        THEN getvariable('slack_raw_path')
    ELSE error('Slack request failed; raw responses saved at ' || getvariable('slack_raw_path'))
END AS raw_path
FROM validated;
