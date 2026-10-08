-- The readers from setup.sql as a stdio MCP server. From the repo root:
--   claude mcp add duckstack -- uvx --from duckdb-cli==1.5.5 duckdb -bail -c ".read server/portable/mcp.sql"
-- stdout is the protocol channel, so the CLI's own result tables go to /dev/null; the server writes past it.
.output /dev/null
SET VARIABLE server_dir = coalesce(nullif(getenv('SERVER_DIR'), ''), '/Users/aloksubbarao/duckdb-skills');
CREATE OR REPLACE TEMPORARY TABLE _portable_boot_files AS
SELECT 1 AS ordinal, 'server/portable/setup.sql' AS relative_path;
SET VARIABLE portable_boot_program = (
    WITH statements AS (
        SELECT ordinal,
               'SELECT ' || ordinal || ' AS ordinal, content FROM read_text(' ||
               chr(39) || replace(getvariable('server_dir') || '/' || relative_path,
                                    chr(39), chr(39) || chr(39)) || chr(39) || ')' AS statement
        FROM _portable_boot_files
    )
    SELECT 'SELECT string_agg(content, chr(10) ORDER BY ordinal) AS program FROM (' ||
           array_to_string(list(statement ORDER BY ordinal), ' UNION ALL ') || ')'
    FROM statements
);
COPY (SELECT program FROM query(getvariable('portable_boot_program')))
TO '/tmp/duckstack-portable-bootstrap.sql' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
.read /tmp/duckstack-portable-bootstrap.sql
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
