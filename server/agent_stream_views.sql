CREATE OR REPLACE VIEW agent.stream_day AS
WITH days AS (
    SELECT system, session_id, day, count(id) AS message_count, min(ts) AS first_ts, max(ts) AS last_ts,
        list(DISTINCT coalesce(nullif(cwd, ''), nullif(project_path, ''))) AS directories,
        list({id: id, uuid: uuid, role: message_role, content: message_content, ts: ts}
            ORDER BY ts DESC NULLS LAST, file_name, line_number, id) AS messages
    FROM agent.stream GROUP BY ALL
)
SELECT * EXCLUDE (messages), list_transform(messages[:10],
    m -> {id: m.id, uuid: m.uuid, role: m.role, text: left(m.content, 150), ts: m.ts}) AS samples
FROM days;

-- Session entry point: only the human/agent exchange appears in the preview.
CREATE OR REPLACE VIEW agent.stream_conversation AS
WITH messages AS (
    SELECT system, session_id, project_path, day, block, ts, id, uuid,
        message_role, message_content,
        row_number() OVER (PARTITION BY system, session_id
            ORDER BY ts DESC NULLS LAST, id DESC) AS recent_rank
    FROM agent.stream
    WHERE message_role IN ('user', 'agent') AND message_content IS NOT NULL
), sessions AS (
    SELECT system, session_id, arg_max(project_path, ts) AS project_path,
        list(DISTINCT day ORDER BY day) AS days,
        min(ts) AS first_ts, max(ts) AS last_ts, count(id) AS message_count,
        list({id: id, uuid: uuid, role: message_role,
              text: left(message_content, 150), ts: ts} ORDER BY ts, id)
            FILTER (WHERE recent_rank <= 10) AS preview
    FROM messages
    GROUP BY system, session_id
)
SELECT * FROM sessions;

CREATE OR REPLACE VIEW agent.stream_freshness AS
WITH latest_attempt AS (
    SELECT * EXCLUDE (freshness_rank)
    FROM (
        SELECT *, row_number() OVER (ORDER BY started_at DESC, run_id DESC) AS freshness_rank
        FROM agent.stream_refresh
    )
    WHERE freshness_rank = 1
), latest_success AS (
    SELECT * EXCLUDE (freshness_rank)
    FROM (
        SELECT *, row_number() OVER (ORDER BY source_coverage_at DESC, run_id DESC) AS freshness_rank
        FROM agent.stream_refresh
        WHERE status = 'success'
    )
    WHERE freshness_rank = 1
), freshness_rows AS (
    SELECT run_id AS latest_attempt_run_id, instance_id AS latest_attempt_instance_id,
           started_at AS latest_attempt_started_at, completed_at AS latest_attempt_completed_at,
           status AS latest_attempt_status, error AS latest_attempt_error,
           NULL::UUID AS latest_success_run_id, NULL::TIMESTAMPTZ AS source_coverage_at,
           NULL::TIMESTAMPTZ AS latest_success_completed_at, NULL::TIMESTAMPTZ AS source_updated_through,
           NULL::BIGINT AS source_rows, NULL::BIGINT AS normalized_rows,
           NULL::BIGINT AS mutated_rows, NULL::BIGINT AS stream_rows
    FROM latest_attempt
    UNION ALL
    SELECT NULL::UUID, NULL::VARCHAR, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::VARCHAR, NULL::VARCHAR,
           run_id, source_coverage_at, completed_at, source_updated_through,
           source_rows, normalized_rows, mutated_rows, stream_rows
    FROM latest_success
), freshness AS (
    SELECT max(latest_attempt_run_id) AS latest_attempt_run_id,
           max(latest_attempt_instance_id) AS latest_attempt_instance_id,
           max(latest_attempt_started_at) AS latest_attempt_started_at,
           max(latest_attempt_completed_at) AS latest_attempt_completed_at,
           max(latest_attempt_status) AS latest_attempt_status, max(latest_attempt_error) AS latest_attempt_error,
           max(latest_success_run_id) AS latest_success_run_id, max(source_coverage_at) AS source_coverage_at,
           max(latest_success_completed_at) AS latest_success_completed_at,
           max(source_updated_through) AS source_updated_through, max(source_rows) AS source_rows,
           max(normalized_rows) AS normalized_rows, max(mutated_rows) AS mutated_rows,
           max(stream_rows) AS stream_rows
    FROM freshness_rows
)
SELECT *, now() - source_coverage_at AS source_snapshot_age,
       source_coverage_at IS NOT NULL
           AND now() - source_coverage_at <= INTERVAL '10 minutes' AS within_ten_minutes
FROM freshness;

-- Create the durable human-text view when the stream first becomes available.
FROM post_file('/Users/aloksubbarao/duckdb-skills/server/agent_user_text.sql');
-- Public reader surfaces use sanitized data, never the reader's raw transcript view.
CREATE OR REPLACE VIEW agent.conversations AS FROM agent.stream;
CREATE OR REPLACE VIEW agent.subagent_chats AS FROM agent.stream WHERE is_agent;
