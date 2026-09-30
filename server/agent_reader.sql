-- Temporary unsigned reader; the signed main database owns the stream and indexes.
LOAD quack;
LOAD '/Users/aloksubbarao/inframe/.agent_data_repair/build/release/agent_data.duckdb_extension';

CREATE VIEW conversations AS
SELECT 'claude' AS system, *
FROM read_conversations(path := '~/.claude', source := 'claude')
UNION ALL BY NAME
SELECT 'claude-desktop' AS system, *
FROM read_conversations(path := '~/Library/Application Support/Claude', source := 'claude-desktop')
UNION ALL BY NAME
SELECT 'codex' AS system, *
FROM read_conversations(path := '~/.codex', source := 'codex');

SELECT * FROM quack_serve('quack:127.0.0.1:19494', token := getenv('QUACK_TOKEN'));
