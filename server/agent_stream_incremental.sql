-- Read one full snapshot, normalize locally, and mutate only changed stream rows.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE TABLE IF NOT EXISTS agent.stream_refresh (
    run_id UUID PRIMARY KEY,
    instance_id VARCHAR,
    started_at TIMESTAMPTZ NOT NULL,
    source_coverage_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    status VARCHAR NOT NULL,
    error VARCHAR,
    source_updated_through TIMESTAMPTZ,
    source_rows BIGINT,
    normalized_rows BIGINT,
    mutated_rows BIGINT,
    stream_rows BIGINT
);
ALTER TABLE agent.stream_refresh ADD COLUMN IF NOT EXISTS mutated_rows BIGINT;

CREATE OR REPLACE TEMP TABLE stream_run AS
SELECT uuid() AS run_id, getenv('QUACK_INSTANCE_ID') AS instance_id,
       now() AS started_at, now() AS source_coverage_at;

INSERT INTO agent.stream_refresh BY NAME
SELECT run_id, instance_id, started_at, source_coverage_at, NULL AS completed_at,
       'running' AS status, NULL AS error, NULL AS source_updated_through,
       NULL::BIGINT AS source_rows, NULL::BIGINT AS normalized_rows,
       NULL::BIGINT AS mutated_rows, NULL::BIGINT AS stream_rows
FROM stream_run;

-- The reader is authoritative: take one complete snapshot, then normalize locally.
CREATE OR REPLACE TEMP TABLE stream_source AS
FROM quack_query('quack:127.0.0.1:19494',
    $reader$SELECT * EXCLUDE (raw_event, metadata,
        input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, reasoning_tokens)
    FROM conversations$reader$,
    token := getenv('QUACK_TOKEN'));

CREATE OR REPLACE TEMP TABLE stream_delta AS
WITH source_rows AS (
    -- speaker: the source's role when it has one, else its record type.
    SELECT *, CASE WHEN message_role <> '' THEN message_role ELSE message_type END AS speaker,
        -- event_kind is derived, so its values never collide with a source's own type names.
        CASE WHEN message_type IN ('function_call_output', 'custom_tool_call_output', 'tool_result') THEN 'call_result'
             WHEN message_type IN ('function_call', 'custom_tool_call', 'tool_call') THEN 'call_request'
             WHEN tool_input <> '' THEN 'call_request'
             WHEN speaker = 'tool' THEN 'call_result'
             WHEN tool_name <> '' THEN 'call_request'
             WHEN speaker = 'user' THEN 'user_text'
             WHEN speaker IN ('assistant', 'reasoning', 'agent_message') THEN 'agent_text'
             WHEN speaker IN ('system', 'developer') THEN 'system_text'
             WHEN message_type = '_parse_error' THEN 'reader_error'
             WHEN message_type IN ('token_usage', 'token_usage_total', 'token_count') THEN 'token_count'
             WHEN message_type IN ('attachment', 'image_view') THEN 'attachment'
             WHEN message_type IN ('file_change', 'file-history-snapshot', 'file-history-delta') THEN 'file_edit'
             WHEN message_type IN ('inter_agent_communication_metadata', 'subagent_activity') THEN 'subagent_link'
             WHEN message_type IN ('queue-operation', 'task_started', 'task_complete', 'turn_aborted', 'compacted',
                 'compaction', 'compaction_summary', 'retained_context', 'plan') THEN 'turn_lifecycle'
             WHEN message_type IN ('last-prompt', 'ai-title', 'custom-title', 'agent-name', 'agent-setting', 'mode',
                 'permission-mode', 'pr-link', 'frame-link', 'bridge-session', 'worktree-state', 'relocated',
                 'continued-in', 'history-suppression', 'cost-state', 'atis-latch', 'artifact-autoreact-ledger',
                 'artifact-comment-monitor', 'world_state', 'thread_settings_applied', 'extension') THEN 'session_state'
             ELSE 'unlabeled' END AS event_kind,
        sha256(to_json({system: system, session_id: session_id, file_name: file_name,
            project_path: project_path, line_number: line_number, uuid: uuid,
            message_type: message_type, tool_use_id: tool_use_id})) AS source_key,
        row_number() OVER (PARTITION BY source_key
            ORDER BY timestamp, sha256(message_content), tool_name, sha256(tool_input)) AS occurrence
    FROM stream_source
), parts AS (
    SELECT *, 'text' AS part, nullif(message_content, '') AS content, NULL AS tool_data
    FROM source_rows
    WHERE CASE WHEN event_kind <> 'call_request' THEN true
        WHEN speaker IN ('user', 'assistant') THEN message_content <> ''
        WHEN speaker = 'tool' AND message_type NOT IN ('function_call', 'custom_tool_call', 'tool_call')
            THEN message_content <> '' ELSE false END
    UNION ALL BY NAME
    SELECT *, 'tool' AS part,
        nullif(concat_ws(' ', nullif(tool_name, ''),
            CASE WHEN tool_input <> '' THEN tool_input
                 WHEN speaker IN ('user', 'assistant') THEN NULL
                 ELSE nullif(message_content, '') END), '') AS content,
        {name: tool_name, input: tool_input, call_id: tool_use_id} AS tool_data
    FROM source_rows WHERE event_kind = 'call_request'
), normalized AS (
    SELECT COLUMNS(c -> c NOT IN ('tool_name', 'tool_input', 'raw_event', 'metadata', 'session_updated_at',
        'source_key', 'occurrence', 'part', 'speaker', 'content', 'message_role', 'message_content',
        'input_tokens', 'output_tokens', 'cache_creation_tokens', 'cache_read_tokens', 'reasoning_tokens')),
        message_role AS source_message_role, source_key || ':' || occurrence || ':' || part AS id,
        -- A call row's text part keeps its speaker's role; event_kind stays the row's kind.
        CASE WHEN part = 'tool' THEN 'tool_call'
             WHEN message_type IN ('function_call_output', 'custom_tool_call_output', 'tool_result') THEN 'tool_result'
             WHEN speaker = 'tool' THEN 'tool_result'
             WHEN speaker = 'user' THEN 'user'
             WHEN speaker IN ('assistant', 'reasoning', 'agent_message') THEN 'agent'
             WHEN speaker IN ('system', 'developer') THEN 'system' ELSE 'other' END AS message_role,
        content AS message_content, length(content) AS content_length,
        try_cast(timestamp AS TIMESTAMPTZ) AS ts,
        (ts AT TIME ZONE 'UTC')::DATE AS day, time_bucket(INTERVAL '5 minutes', ts) AS block
    FROM parts
)
SELECT *, CASE WHEN content_length > 2000
    THEN left(message_content, 1000) || ' … ' || right(message_content, 997)
    ELSE message_content END AS content_headtail
FROM normalized;

-- The volume floor catches major source loss, not completeness; bulk removal needs inspection.
CREATE OR REPLACE TEMP TABLE stream_preflight_observations AS
SELECT count(1) AS source_rows, NULL::BIGINT AS delta_rows,
       NULL::BIGINT AS nonnull_ids, NULL::BIGINT AS distinct_ids,
       NULL::BIGINT AS previous_source_rows
FROM stream_source
UNION ALL
SELECT NULL::BIGINT, count(1), count(id), count(DISTINCT id), NULL::BIGINT
FROM stream_delta
UNION ALL
SELECT NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, source_rows
FROM (
    SELECT source_rows, row_number() OVER (ORDER BY source_coverage_at DESC, run_id DESC) AS prior_rank
    FROM agent.stream_refresh
    WHERE status = 'success'
)
WHERE prior_rank = 1;
CREATE OR REPLACE TEMP TABLE stream_preflight AS
SELECT max(source_rows) AS source_rows, max(delta_rows) AS delta_rows,
       max(nonnull_ids) AS nonnull_ids, max(distinct_ids) AS distinct_ids,
       max(previous_source_rows) AS previous_source_rows
FROM stream_preflight_observations;
SELECT CASE WHEN source_rows = 0 THEN error('stream source is empty')
            WHEN delta_rows IS DISTINCT FROM nonnull_ids THEN error('stream source has NULL ids')
            WHEN delta_rows IS DISTINCT FROM distinct_ids THEN error('stream source has duplicate ids')
            WHEN previous_source_rows IS NOT NULL AND source_rows < previous_source_rows * 0.95
                THEN error('stream source fell below 95 percent of the last successful snapshot')
            ELSE 'stream preflight passed' END AS preflight
FROM stream_preflight;

CREATE TABLE IF NOT EXISTS agent.stream AS SELECT * FROM stream_delta WHERE false;
-- This is session transport metadata, not event data; old normalized tables retained it.
ALTER TABLE agent.stream DROP COLUMN IF EXISTS session_updated_at;
ALTER TABLE agent.stream ADD COLUMN IF NOT EXISTS event_kind VARCHAR;
-- Keep only IDs for accounting; MERGE owns full-row comparison atomically.
CREATE OR REPLACE TEMP TABLE stream_mutation_ids AS
SELECT s.id
FROM stream_delta AS s
ANTI JOIN agent.stream AS t USING (id)
UNION ALL
SELECT s.id
FROM stream_delta AS s
JOIN agent.stream AS t USING (id)
WHERE t IS DISTINCT FROM s
UNION ALL
SELECT t.id
FROM agent.stream AS t
ANTI JOIN stream_delta AS s USING (id);

MERGE INTO agent.stream AS dst
USING stream_delta AS src
ON dst.id = src.id
WHEN MATCHED AND dst IS DISTINCT FROM src THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
WHEN NOT MATCHED BY SOURCE THEN DELETE;

CREATE OR REPLACE TEMP TABLE stream_refresh_result AS
SELECT max(greatest(coalesce(try_cast(session_updated_at AS TIMESTAMPTZ),
                            to_timestamp(try_cast(session_updated_at AS DOUBLE))),
                    try_cast(timestamp AS TIMESTAMPTZ)))
           AS source_updated_through,
       count(1) AS source_rows,
       NULL::BIGINT AS normalized_rows, NULL::BIGINT AS mutated_rows, NULL::BIGINT AS stream_rows
FROM stream_source
UNION ALL
SELECT NULL::TIMESTAMPTZ, NULL::BIGINT, count(id), NULL::BIGINT, NULL::BIGINT FROM stream_delta
UNION ALL
SELECT NULL::TIMESTAMPTZ, NULL::BIGINT, NULL::BIGINT, count(id), NULL::BIGINT FROM stream_mutation_ids
UNION ALL
SELECT NULL::TIMESTAMPTZ, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, count(id) FROM agent.stream;
CREATE OR REPLACE TEMP TABLE stream_refresh_summary AS
SELECT max(source_updated_through) AS source_updated_through,
       sum(source_rows) AS source_rows, sum(normalized_rows) AS normalized_rows,
       sum(mutated_rows) AS mutated_rows, sum(stream_rows) AS stream_rows
FROM stream_refresh_result;
SET VARIABLE stream_run_id = (SELECT run_id FROM stream_run);

UPDATE agent.stream_refresh AS r
SET completed_at = now(), status = 'success', source_updated_through = s.source_updated_through,
    source_rows = s.source_rows, normalized_rows = s.normalized_rows,
    mutated_rows = s.mutated_rows, stream_rows = s.stream_rows
FROM stream_refresh_summary AS s
WHERE r.run_id = getvariable('stream_run_id')::UUID;

SELECT * FROM agent.stream_refresh
WHERE run_id = getvariable('stream_run_id')::UUID;
