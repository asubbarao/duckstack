---
name: agent-stream
description: Find recent or relevant agent conversations (Claude Code, Claude Desktop, Codex), then drill into complete messages and tool activity.
allowed-tools: mcp__dev__query
---

# Agent stream

Agent data is agent_data's own readers, called directly on dev through `mcp__dev__query`.
There are no wrapper views and no copies.

| Reader | One row per |
|---|---|
| `read_conversations(source := …, path := …)` | transcript event (message, tool call, tool result) |
| `read_history(source := …, path := …)` | prompt typed at the CLI |
| `read_plans(source := …, path := …)` | plan file |
| `read_todos(source := …, path := …)` | todo item |

The stores, one call each:

| source | path |
|---|---|
| `'claude'` | `getenv('HOME') || '/.claude'` |
| `'claude-desktop'` | `getenv('HOME') || '/Library/Application Support/Claude'` |
| `'codex'` | `getenv('HOME') || '/.codex'` |

Read one store per call. Claude reads in about 3 s; Codex in about 150 s (2026-10-09), so ask for
Codex only when the question is about Codex.

```sql
SELECT session_id, timestamp, message_role, tool_name, left(message_content, 200) AS head
FROM read_conversations(source := 'claude', path := getenv('HOME') || '/.claude')
WHERE timestamp::TIMESTAMPTZ > now() - INTERVAL 12 HOUR
ORDER BY timestamp DESC
LIMIT 20;
```

## Keys and identity

- A transcript line is `(session_id, file_name, line_number)`. That is the key.
- `uuid` is not unique: Codex reuses one uuid for several events in a file, so never deduplicate on it.
- `timestamp` is an ISO string; cast with `timestamp::TIMESTAMPTZ` when you need time arithmetic.
- Full text is `message_content`; select a head (`left(message_content, 200)`) unless you need all of it.

## Search

Search is a WHERE over the reader. Keep the terms as an array and intersect, rather than chaining text predicates:

```sql
WITH m AS (
    SELECT session_id, timestamp, tool_name, message_content,
           ['webbed', 'crawler', 'tera', 'shellfs'] AS terms,
           string_split(lower(coalesce(message_content, '')), ' ') AS tokens
    FROM read_conversations(source := 'claude', path := getenv('HOME') || '/.claude')
)
SELECT session_id, timestamp, tool_name, array_intersect(tokens, terms) AS matched, left(message_content, 200) AS head
FROM m WHERE len(array_intersect(tokens, terms)) > 0
ORDER BY timestamp DESC LIMIT 20;
```

## Subagent relationships

`is_agent` is provider-specific classification, not a parent link. Native Codex children carry
`parent_session_id`, `agent_path` and `thread_source = 'subagent'`; a separately launched `codex exec`
has `thread_source = 'exec'` and no parent. Claude child transcripts carry the parent's `session_id`:
tell siblings apart by `file_name`. `parent_uuid` links messages, not conversations.
