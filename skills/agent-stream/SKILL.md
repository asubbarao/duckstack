---
name: agent-stream
description: >
  Search and read every agent conversation on this machine — Claude Code, Claude Desktop, Codex —
  as one table on dev, refreshed every 5 minutes. Use when asked to find a past conversation
  ("the codex chat about X", "what did I say about Y"), to read what the user typed recently, to
  continue earlier work, or to check what an agent actually ran. MCP tools: stream_search,
  stream_session, user_messages. Never grep transcript files or read ~/.claude by hand.
argument-hint: "[search words | session_id | hours]"
allowed-tools: Bash, mcp__dev__stream_search, mcp__dev__stream_session, mcp__dev__user_messages, mcp__dev__query, mcp__dev__sql
---

# agent-stream

Every transcript on this machine is read by `agent_data`'s `read_conversations()` into one table
on dev, `agent.stream`, and indexed for BM25. A dev cron re-derives it every 5 minutes from the
JSONL files (`~/.duck/agent_stream/agent_stream.sql`), so it is never more than 5 minutes behind.

## The three calls (the `dev` MCP)

| tool | argument | gives |
|---|---|---|
| `stream_search` | `q` — search words | the 50 best-matching messages, any role, with `session_id` |
| `stream_session` | `session_id` | that conversation hour by hour, in order |
| `user_messages` | `hours` | what the user typed in the last N hours, per session per hour |

Find, then read: `stream_search` → take the `session_id` → `stream_session`. Two calls, not a
hunt through files.

## The table, for anything the tools do not cover (the `query` / `sql` tools)

`agent.stream` — one row per thing said or done:

| column | what |
|---|---|
| `message_role` | `user` (a person typed it), `agent` (a model wrote it, reasoning included), `tool_call` (a call and what came back) |
| `message_content` | the text; a tool call is its name and arguments |
| `shape` | NULL, or which part of a >9,999-char message is kept (`head`, `tail`, `both_ends`, `whole`) — the full text is in `agent.records` |
| `system`, `session_id`, `ts`, `day`, `hour`, `line_number`, `is_agent`, `slug`, `cwd`, `git_branch`, `model` | where and when |

Harness text written into the user channel — task notifications, interruptions, command
wrappers, AGENTS.md, environment context — is already excluded, so `message_role = 'user'` is
what a person typed.

Also on dev: `agent.stream_hour` (a session's messages per hour, in order), `agent.sessions`
(one row per session), `agent.records` (every raw row the reader emits, nothing dropped),
`agent.plans`.

BM25 directly:

```sql
SELECT s.session_id, s.ts, s.message_role, left(s.message_content, 300) AS snippet, h.score
FROM (SELECT id, fts_agent_stream.match_bm25(id, 'duckdb checkpoint crash') AS score FROM agent.stream) AS h
JOIN agent.stream AS s USING (id)
WHERE h.score IS NOT NULL
ORDER BY h.score DESC LIMIT 20;
```

## Without the MCP

Same SQL, `curl -s -X POST localhost:9495/sql --data-urlencode sql@query.sql` (see
`/duckstack:agent-door`).

Verified 2026-09-22: `stream_search` for "force checkpoint fts crash" returned this session's
tool calls from minutes earlier; `user_messages` and `stream_session` returned rows; the index
survives a dev restart.
