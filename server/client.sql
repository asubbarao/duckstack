-- An agent session's own DuckDB MCP server over stdio. Each Claude Code or Codex session starts one:
--   duckdb :memory: -f /Users/aloksubbarao/.duck/deploy/server/client.sql
-- ~/.duckdbrc runs first, as in every local duckdb: 4 GiB memory, 4 threads, the temp floor, the query log, and dev's
-- extensions.sql and macros.sql. So this file only starts the server. It needs nothing from dev to start or to answer,
-- so a dev restart cannot disconnect it; what needs dev's state goes there per call with selfdispatch(sql), and only
-- that call fails while dev is down. stdout carries the protocol, so nothing below may print.
.output /dev/null
SET GLOBAL TimeZone = 'UTC';
INSTALL duckdb_mcp FROM community;
LOAD duckdb_mcp;
-- Dev's views that are only files and host commands, here too, so they answer while dev is down.
.read /Users/aloksubbarao/.duck/deploy/server/host.sql
-- Every transcript line, read live from the .jsonl files: one raw json column, parsed at use (json ->> 'timestamp').
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.lines AS
SELECT filename, json FROM read_json_objects([getenv('HOME') || '/.claude/projects/*/*.jsonl',
    getenv('HOME') || '/.claude/projects/*/*/subagents/*.jsonl', getenv('HOME') || '/.codex/sessions/*/*/*/*.jsonl'],
    format := 'newline_delimited', filename := true, ignore_errors := true, maximum_object_size := 268435456);
-- Every memory, plan and instruction file Claude and Codex keep, one row per file, read live.
CREATE OR REPLACE VIEW agent.docs AS
SELECT filename AS path, file_name(filename) AS name, size, last_modified, content
FROM read_text(['/Users/aloksubbarao/.claude/projects/*/memory/*.md', '/Users/aloksubbarao/.claude/plans/*.md',
    '/Users/aloksubbarao/.codex/memories/*.md', '/Users/aloksubbarao/.codex/memories/*/*/*/*.md',
    '/Users/aloksubbarao/.claude/CLAUDE.md', '/Users/aloksubbarao/AGENTS.md', '/Users/aloksubbarao/.codex/AGENTS.md']);
-- Dev's two tools, query {sql} and execute {statement}, and no others.
-- query is our own tool, not the built-in one: the built-in refuses any SQL that names read_text, read_json,
-- read_csv, read_parquet or glob. query() is DuckDB's table function that runs one SELECT given as text.
PRAGMA mcp_publish_tool('query',
    'Run one SELECT in this session''s own DuckDB (dev''s extensions and macros; shellfs, read_text, read_json all work). Returns the rows as JSON; a failure returns the DuckDB error. For dev''s tables and state, post SQL to dev per row and unnest the receipts: WITH statements AS (SELECT key, sql FROM ...), posted AS (SELECT array_agg({key: key, receipt: selfdispatch(sql)}) AS receipts FROM statements) SELECT t.r.key, t.r.receipt.status, t.r.receipt.error, t.r.receipt.body FROM posted CROSS JOIN UNNEST(receipts) AS t(r). A failed post stays a receipt (status 0 while dev is down); this session is unaffected.',
    'FROM query($sql)',
    '{"sql": {"type": "string", "description": "One SELECT statement"}}',
    '["sql"]',
    'json');
-- execute is the built-in one, which takes {statement}: DDL, DML, INSTALL/LOAD and ATTACH. It refuses SELECT, COPY,
-- CALL and PRAGMA whatever the config says. SET stays off: SET threads from a tool call breaks the thread pool and
-- every call after it, and the memory cap should hold. The server holds the process here until stdin closes.
PRAGMA mcp_server_start('stdio', '{
    "builtin_tools": false,
    "enable_query_tool": false,
    "enable_execute_tool": true,
    "execute_allow_load": true,
    "execute_allow_attach": true,
    "execute_allow_set": false,
    "default_result_format": "json"
}');
