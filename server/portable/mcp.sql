-- The readers from setup.sql as a stdio MCP server. From the repo root:
--   claude mcp add duckstack -- uvx --from duckdb-cli==1.5.5 duckdb -bail -c ".read server/portable/mcp.sql"
-- stdout is the protocol channel, so the CLI's own result tables go to /dev/null; the server writes past it.
.output /dev/null
.read server/portable/setup.sql
INSTALL duckdb_mcp FROM community;
LOAD duckdb_mcp;
-- A trusted-local reader surface. The built-in query tool deliberately rejects file readers.
-- The SQL argument is bound by duckdb_mcp, not spliced into a shell command.
PRAGMA mcp_publish_tool(
    'query_sql', 'Run one relational SQL query, including installed file and ShellFS readers.',
    'SELECT * FROM query($sql)',
    '{"sql":{"type":"string","description":"One SQL query; bound as a query() argument."}}',
    '["sql"]'
);
PRAGMA mcp_server_start('stdio', '{"builtin_tools":false}');
