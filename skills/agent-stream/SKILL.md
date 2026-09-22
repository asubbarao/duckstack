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
on dev, `agent.stream`, and indexed for BM25 in ordinary tables (`agent.bm25_*`). A dev cron re-derives it every 5 minutes from the
JSONL files (`~/.duck/agent_stream/agent_stream.sql`), so it is never more than 5 minutes behind.

## The three calls (the `dev` MCP)

| tool | argument | gives |
|---|---|---|
| `stream_search` | `q` — search words or a question | one row per matching session (BM25 + vector, fused), with its best messages |
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

The query `stream_search` runs is `~/.duck/agent_stream/agent_stream_search.sql`: the search words
are tokenized exactly as the messages were (fts's own `stem()` and stopwords), then BM25 in the fts
extension's form (k1 = 1.2, b = 0.75) scores each message over `agent.bm25_posting` /
`agent.bm25_length`, and a session ranks by its best message (MaxP). The same text is embedded in
dev (`embed()`) and each session ranked by its nearest message vector (`agent.stream_vec`); the two
rankings are fused by reciprocal rank (k = 60). On 224 known-answer probes (MRR title / whole-chat /
moment): fused 0.607 / 0.462 / 0.317, BM25 alone 0.51 / 0.466 / 0.302, vector alone 0.599 / 0.395 /
0.319, the old hour search 0.416 / 0.385 / 0.272. Copy it and change the one literal in its `asked` CTE to run it by hand.

## Never build an FTS index on dev

BM25 here is ordinary tables — `agent.bm25_posting` (term, tf per message) and `agent.bm25_length` —
kept by the 5-minute cron with inserts and deletes. Do not run `PRAGMA create_fts_index` or
`drop_fts_index` against dev: an index drop left in the write-ahead log does not replay on DuckDB
1.5.5, and dev then fails to start (2026-09-22). Search with `stream_search` or the tables.

## Without the MCP

Same SQL, `curl -s -X POST localhost:9495/sql --data-urlencode sql@query.sql` (see
`/duckstack:agent-door`).

Verified 2026-09-22: a word typed at 15:11 had no postings, then 4 after the 15:15 run, and
`stream_search` found it after a dev restart; every message in agent.stream has a length row and
its term counts sum to it; `user_messages` and `stream_session` return rows.
