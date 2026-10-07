-- Temporary unsigned reader; the signed main database owns the stream and indexes.
LOAD quack;
LOAD '/Users/aloksubbarao/.duck/reader-artifacts/44494e6/agent_data.duckdb_extension';

CREATE VIEW conversations AS
WITH source_rows AS (
    SELECT 'claude' AS system, *
    FROM read_conversations(path := '~/.claude', source := 'claude')
    UNION ALL BY NAME
    SELECT 'claude-desktop' AS system, *
    FROM read_conversations(path := '~/Library/Application Support/Claude', source := 'claude-desktop')
    UNION ALL BY NAME
    SELECT 'codex' AS system, *
    FROM read_conversations(path := '~/.codex', source := 'codex')
)
SELECT * EXCLUDE (message_content, tool_use_id),
    coalesce(nullif(message_content, ''),
        CASE WHEN nullif(message_content, '') IS NULL
            THEN nullif(json_extract_string(try_cast(raw_event AS JSON),
                '$.message.content[0].content'), '') END) AS message_content,
    coalesce(nullif(tool_use_id, ''),
        CASE WHEN nullif(tool_use_id, '') IS NULL
            THEN nullif(json_extract_string(try_cast(raw_event AS JSON),
                '$.message.content[0].tool_use_id'), '') END) AS tool_use_id,
    CASE WHEN message_type = 'attachment'
        THEN json_extract_string(try_cast(raw_event AS JSON), '$.attachment.type') END AS attachment_type,
    octet_length(encode(raw_event)) AS raw_bytes
FROM source_rows;

SELECT * FROM quack_serve('quack:127.0.0.1:19494', token := getenv('QUACK_TOKEN'));
