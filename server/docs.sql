-- agent.docs: every memory, plan and instruction file Claude and Codex keep, one row per file, read live, on dev.
-- Posted, so a home missing one of the folders gets a failed
-- receipt instead of a failed boot (read_text fails to bind on a glob that matches nothing).
CREATE SCHEMA IF NOT EXISTS agent;
WITH intent AS (
    SELECT $d$
CREATE OR REPLACE VIEW agent.docs AS
SELECT filename AS path, file_name(filename) AS name, size, last_modified, content
FROM read_text(list_transform(['/.claude/projects/*/memory/*.md', '/.claude/plans/*.md', '/.codex/memories/*.md',
    '/.codex/memories/*/*/*/*.md', '/.claude/CLAUDE.md', '/AGENTS.md', '/.codex/AGENTS.md'], lambda p: concat(getenv('HOME'), p)))
$d$ AS sql
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM intent
)
SELECT r.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(r);
