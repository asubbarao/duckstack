-- Run from this workspace: duckdb :memory: < outputs/sql/linear.sql
-- Then SELECT * FROM linear_raw_responses; each scan fetches again.
-- Requires curl, jq, LINEAR_API_KEY. Credentials stay out of rendered text.
-- LINEAR_URL selects one issue; otherwise defaults to yesterday UTC.
-- This is an issue snapshot by updatedAt, not an event log/comment export.
.bail on
LOAD tera;
LOAD shellfs;
LOAD read_lines;
.read outputs/sql/interval.sql

CREATE OR REPLACE VIEW linear_raw_responses AS
WITH configuration AS (
    SELECT *, nullif(getenv('LINEAR_URL'), '') AS target_url,
        json_object(
            'single', target_url IS NOT NULL, 'type', 'Issue',
            'collection', 'issues', 'item', 'issue',
            'fields', 'id identifier title description url createdAt updatedAt archivedAt
                state { id name } assignee { id name } team { id key name }',
            'arguments', 'first: 100, after: $after, filter: $filter, includeArchived: true'
        ) AS document,
        CASE WHEN target_url IS NULL THEN json_object('filter', json_object(
            'updatedAt', json_object('gte', window_start, 'lt', window_end)))
        ELSE json_object('id', split_part(target_url, '/', 6)) END AS variables
    FROM ingestion_interval
), request AS (
    SELECT *, json_object('query', tera_render('tera_graphql.tera', document,
        template_path := 'outputs/sql/templates/*.tera', autoescape := false),
        'variables', variables) AS payload
    FROM configuration
), transport AS (
    SELECT *, tera_render('tera_graphql_pages.tera', json_object(
        'endpoint', 'https://api.linear.app/graphql', 'auth_env', 'LINEAR_API_KEY',
        'payload_base64', to_base64(encode(payload::VARCHAR)),
        'page_path', CASE WHEN target_url IS NULL THEN 'data.issues.pageInfo' ELSE '' END
    ), template_path := 'outputs/sql/templates/*.tera', autoescape := false) AS command
    FROM request
)
SELECT 'linear' AS source_id, window_start, window_end,
    content::JSON AS http_response
FROM transport CROSS JOIN LATERAL read_lines_lateral(transport.command);

DESCRIBE linear_raw_responses;
