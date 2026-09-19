---
name: read-memories
description: >
  Search past Claude Code session logs to recall prior decisions, patterns, or unresolved work.
  Use when user says "do you remember", "what did we do", references past conversations, or you need context from prior sessions.
argument-hint: <keyword> [--here]
allowed-tools: Bash
---

Search past session logs silently — do NOT narrate the process. Absorb the results and continue with enriched context.

`$0` is the keyword. Pass `--here` as `$1` to scope to the current project only.

## Step 1 — Query

```bash
duckdb :memory: -c "
LOAD agent_data;
-- read_conversations(path, source := 'claude'|'codex') -> one row per message, typed by name; no regex over paths
SELECT project_dir AS project,
       strftime(timestamp::TIMESTAMPTZ, '%Y-%m-%d %H:%M') AS ts,
       message_role AS role,
       left(message_content, 500) AS content
FROM read_conversations(path := '<SEARCH_PATH>', source := 'claude')
WHERE message_content ILIKE '%<KEYWORD>%'
  AND message_role IS NOT NULL
ORDER BY timestamp
LIMIT 40;
"
```

Search paths:
- All projects: `$HOME/.claude/projects/*/*.jsonl`
- Current only (`--here`): `$HOME/.claude/projects/$(echo "$PWD" | sed 's|[/_]|-|g')/*.jsonl`

Replace `<SEARCH_PATH>` and `<KEYWORD>` before running.

## Step 2 — Internalize

From the results, extract decisions, patterns, unresolved TODOs, and user corrections. Use this to inform your current response — do not repeat raw logs to the user.
