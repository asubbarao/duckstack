-- agent.docs: every memory, plan and instruction file Claude and Codex keep, one row per file, read live. Read by
-- setup.sql (dev) and client.sql (each session's own DuckDB). Every glob names a folder that always holds files.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.docs AS
SELECT filename AS path, file_name(filename) AS name, size, last_modified, content
FROM read_text(list_transform(['/.claude/projects/*/memory/*.md', '/.claude/plans/*.md', '/.codex/memories/*.md',
    '/.codex/memories/*/*/*/*.md', '/.claude/CLAUDE.md', '/AGENTS.md', '/.codex/AGENTS.md'], lambda p: concat(getenv('HOME'), p)));
