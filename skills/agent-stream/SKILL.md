---
name: agent-stream
description: Find recent or relevant agent conversations (Claude Code, Codex) from dev's transcript store, then drill into complete messages and tool activity.
allowed-tools: mcp__dev__query
---

# Agent stream

Start from `agent.messages`: one row per message block, agent_data's column names (`source, session_id, file_path,
is_agent, timestamp, message_role, block_type, tool_name, tool_use_id, uuid, model, cwd, git_branch, entrypoint`),
plus `is_prompt` (a person's typed message), `content_bytes`, and `head`/`tail` (first and last 100 characters) in
place of the full text, so a 290 KB paste never fills a reply. Search and list there; the full text of a row you
picked is `agent.lines.message` (or `payload` for Codex) on the same `uuid`. Never unpack
`agent.lines` JSON by hand, never `read_conversations`, and never read `lake.agent.stream` (stale since 2026-10-12).

```sql
SELECT timestamp, session_id, content_bytes, head, tail FROM agent.messages
WHERE is_prompt AND timestamp > now() - INTERVAL 3 DAY ORDER BY timestamp;
```

The raw store below is for what `agent.messages` doesn't carry.

## The store

- **Where:** one Parquet per session under `~/.duck/lake/agent`, at the session's own path
  (`~/.duck/lake/agent/Users/<you>/.claude/projects/<project>/<session>.parquet`, Codex rollouts likewise).
- **Coverage:** every Claude Code and Codex transcript. A Claude session's Parquet holds its main file and its
  `subagents/*.jsonl`.
- **Feed:** boot and a cron every 5 minutes copy each session whose transcript changed since its stored copy, then
  re-post `agent.lines` over the stored files. So the store is up to ~5 minutes behind live.

| View | One row per |
|---|---|
| `agent.entries` | transcript file or stored Parquet: `path, parent, name, stem, ext, bytes, modified, reader, session` |
| `agent.lines` | transcript line: every top-level field as a `JSON` column, plus `transcript` (the source file's path) |

- `session` (from `agent.entries`) is the session's path without extension; join `agent.entries e ON e.path = l.transcript`.
  Claude subagent files share their parent's `session`; `contains(transcript, '/subagents/')` marks them.
  Each Codex thread is its own session.
- `contains(transcript, '/.codex/')` tells Codex from Claude.
- `(timestamp ->> '$')::TIMESTAMPTZ` is the line's time. There is no line number: order by that time within a
  `transcript`.
- **Claude** lines: `type` is `user`/`assistant`/`system`/…; `message` holds `role` and `content`, a string or an
  array of blocks (`text`, `thinking`, `tool_use` with `id, name, input`, `tool_result`).
- **Codex** lines: `type` is `session_meta`, `turn_context`, `response_item`, `event_msg`, …; `payload ->> 'type'`
  is `message` (`role`, `content` blocks `input_text`/`output_text`), `agent_message`, `reasoning`,
  `function_call` (`name`, `arguments` as JSON text, `call_id`), `custom_tool_call` (`name`, `input` as text).
- If a filter on several `payload` fields fails with `Failed to cast value to numerical`, project them as columns
  in one CTE and filter in the next.

## Rules

- **One statement covers every session.** Filter by a time window, `transcript IN (…)` or `session IN (…)`.
  Never one query per file.
- **Keep rows.**
  - No `QUALIFY row_number() = 1` dedup and no `left()` cuts.
  - Size text with `strlen`.
  - Pick a row with an ASOF join or `arg_max`.
  - A resumed or forked Claude transcript repeats earlier tool calls; count each call once by its first time
    (`min(ts)` per call id, then a SEMI JOIN), as in the external-actions query.
- **Oversized results:** when a result is too big for the tool, it is saved as JSON under the session's
  `tool-results/`. Query that file with `read_json('<file>')`; don't re-run the query.
- **Briefs:** a subagent brief names `agent.lines` and the query below. Never point it at a store root.
- **agent_data:** `read_conversations` is only for one file the store doesn't hold yet, with
  `path := '<that file>'`. Never point it at `~/.claude` or `~/.codex`.

## Turns: each prompt and the reply that closed it

Each prompt pairs with the last assistant text before the next prompt. `reply IS NULL` means no reply yet.

```sql
WITH recent AS (
  SELECT e.session, l.transcript, (l.timestamp ->> '$')::TIMESTAMPTZ AS ts,
         CASE WHEN contains(l.transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
         contains(l.transcript, '/subagents/') AS is_subagent,
         CASE WHEN l.type ->> '$' IN ('user', 'assistant') THEN l.message
              WHEN l.payload ->> 'type' IN ('message', 'agent_message') THEN l.payload END AS msg
  FROM agent.lines l JOIN agent.entries e ON e.path = l.transcript
  WHERE (l.timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 2 DAY
), messages AS (
  SELECT session, transcript, ts, source, is_subagent, role, coalesce(block ->> 'text', block ->> '$') AS text
  FROM (SELECT *, coalesce(msg ->> 'role', 'agent') AS role,
               unnest(CASE json_type(msg -> 'content') WHEN 'ARRAY' THEN json_extract(msg, '$.content[*]') ELSE [msg -> 'content'] END) AS block
        FROM recent WHERE msg IS NOT NULL)
  WHERE coalesce(block ->> 'type', 'text') IN ('text', 'input_text', 'output_text')
), prompts AS (
  SELECT source, session, transcript, ts, text AS prompt,
         lead(ts) OVER (PARTITION BY transcript ORDER BY ts) AS next_prompt_ts
  FROM messages
  WHERE role = 'user' AND NOT is_subagent
    AND NOT starts_with(ltrim(text), '<')                         -- harness tags, reminders
    AND NOT starts_with(text, '# AGENTS.md instructions')         -- Codex instruction preamble
    AND NOT starts_with(text, 'This session is being continued')  -- compaction summaries
), replies AS (
  SELECT transcript, ts AS reply_ts, text AS reply FROM messages WHERE role = 'assistant' AND NOT is_subagent
), turns AS (
  SELECT p.*, CASE WHEN r.reply_ts > p.ts THEN r.reply_ts END AS reply_ts,
              CASE WHEN r.reply_ts > p.ts THEN r.reply END AS reply
  FROM prompts p
  ASOF LEFT JOIN replies r ON r.transcript = p.transcript AND r.reply_ts < coalesce(p.next_prompt_ts, 'infinity'::TIMESTAMPTZ)
)
SELECT source, session, ts, prompt, reply_ts, reply FROM turns ORDER BY session, ts;
```

**One row per session.** This shows where each session stands. The final reply usually lists what it is
waiting on.

```sql
-- same CTEs as above, then:
SELECT source, session, max(ts) AS last_ts, arg_max(prompt, ts) AS last_prompt, arg_max(reply, ts) AS last_reply
FROM turns GROUP BY source, session ORDER BY last_ts DESC;
```

## External actions: PRs, issues, comments, pushes, forks

```sql
WITH recent AS (
  SELECT e.session, l.transcript, (l.timestamp ->> '$')::TIMESTAMPTZ AS ts,
         CASE WHEN contains(l.transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
         contains(l.transcript, '/subagents/') AS is_subagent, l.type ->> '$' AS type, l.message, l.payload
  FROM agent.lines l JOIN agent.entries e ON e.path = l.transcript
  WHERE (l.timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 2 DAY
), calls AS (
  SELECT session, transcript, ts, source, is_subagent, block ->> 'id' AS call_id, block ->> 'name' AS tool_name, block -> 'input' AS input
  FROM (SELECT *, unnest(json_extract(message, '$.content[*]')) AS block FROM recent WHERE type = 'assistant')
  WHERE block ->> 'type' = 'tool_use'
  UNION ALL BY NAME
  SELECT session, transcript, ts, source, is_subagent, payload ->> 'call_id' AS call_id, payload ->> 'name' AS tool_name,
         coalesce(try_cast(payload ->> 'arguments' AS JSON), to_json(payload ->> 'input')) AS input
  FROM recent WHERE payload ->> 'type' IN ('function_call', 'custom_tool_call')
), first_copy AS (
  SELECT call_id, min(ts) AS ts FROM calls GROUP BY call_id
), actions AS (
  SELECT 'pr create' AS action, ['gh', 'pr', 'create'] AS words UNION ALL
  SELECT 'pr comment', ['gh', 'pr', 'comment'] UNION ALL
  SELECT 'pr close', ['gh', 'pr', 'close'] UNION ALL
  SELECT 'pr merge', ['gh', 'pr', 'merge'] UNION ALL
  SELECT 'pr edit', ['gh', 'pr', 'edit'] UNION ALL
  SELECT 'issue create', ['gh', 'issue', 'create'] UNION ALL
  SELECT 'issue comment', ['gh', 'issue', 'comment'] UNION ALL
  SELECT 'fork', ['gh', 'repo', 'fork'] UNION ALL
  SELECT 'push', ['git', 'push']
), cmds AS (
  SELECT c.*, coalesce(input ->> 'command', input ->> 'cmd', input ->> 'sql', input ->> '$', input::VARCHAR) AS cmd
  FROM calls c SEMI JOIN first_copy f ON f.call_id = c.call_id AND f.ts = c.ts
)
SELECT a.action, c.source, c.session, c.transcript, c.ts, c.tool_name, c.is_subagent, c.cmd
FROM cmds c JOIN actions a ON list_has_all(string_split(translate(c.cmd, '''";{}()|&', '         '), ' '), a.words)
ORDER BY c.ts;
```

The words match anywhere in the tool input. A call that only mentions `gh pr create`, such as a search or
a heredoc, also matches, so read `cmd`. Codex's `exec` tool takes JavaScript that calls
`tools.exec_command({cmd: …})`, so its `cmd` is that script.

## Plans

```sql
WITH recent AS (
  SELECT e.session, l.transcript, (l.timestamp ->> '$')::TIMESTAMPTZ AS ts,
         CASE WHEN contains(l.transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
         contains(l.transcript, '/subagents/') AS is_subagent, l.type ->> '$' AS type, l.message, l.payload,
         CASE WHEN l.type ->> '$' IN ('user', 'assistant') THEN l.message
              WHEN l.payload ->> 'type' IN ('message', 'agent_message') THEN l.payload END AS msg
  FROM agent.lines l JOIN agent.entries e ON e.path = l.transcript
  WHERE (l.timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 2 DAY
), messages AS (
  SELECT session, transcript, ts, source, is_subagent, role, coalesce(block ->> 'text', block ->> '$') AS text
  FROM (SELECT *, coalesce(msg ->> 'role', 'agent') AS role,
               unnest(CASE json_type(msg -> 'content') WHEN 'ARRAY' THEN json_extract(msg, '$.content[*]') ELSE [msg -> 'content'] END) AS block
        FROM recent WHERE msg IS NOT NULL)
  WHERE coalesce(block ->> 'type', 'text') IN ('text', 'input_text', 'output_text')
), calls AS (
  SELECT session, transcript, ts, source, is_subagent, block ->> 'name' AS tool_name, block -> 'input' AS input
  FROM (SELECT *, unnest(json_extract(message, '$.content[*]')) AS block FROM recent WHERE type = 'assistant')
  WHERE block ->> 'type' = 'tool_use'
  UNION ALL BY NAME
  SELECT session, transcript, ts, source, is_subagent, payload ->> 'name' AS tool_name,
         coalesce(try_cast(payload ->> 'arguments' AS JSON), to_json(payload ->> 'input')) AS input
  FROM recent WHERE payload ->> 'type' IN ('function_call', 'custom_tool_call')
)
SELECT 'tool' AS via, source, session, transcript, ts, is_subagent, tool_name AS what, input::VARCHAR AS plan
FROM calls WHERE tool_name IN ('ExitPlanMode', 'TodoWrite', 'mcp__ccd_turn__update_plan', 'update_plan')
UNION ALL BY NAME
SELECT 'message' AS via, source, session, transcript, ts, is_subagent, 'proposed_plan' AS what, text AS plan
FROM messages WHERE role = 'assistant' AND starts_with(ltrim(text), '<proposed_plan>')
ORDER BY ts;
```

## Search

Keep the terms as an array and intersect tokens, rather than chaining text predicates:

```sql
WITH recent AS (
  SELECT e.session, l.transcript, (l.timestamp ->> '$')::TIMESTAMPTZ AS ts,
         CASE WHEN contains(l.transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
         CASE WHEN l.type ->> '$' IN ('user', 'assistant') THEN l.message
              WHEN l.payload ->> 'type' IN ('message', 'agent_message') THEN l.payload END AS msg
  FROM agent.lines l JOIN agent.entries e ON e.path = l.transcript
  WHERE (l.timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 7 DAY
), messages AS (
  SELECT session, transcript, ts, source, role, coalesce(block ->> 'text', block ->> '$') AS text
  FROM (SELECT *, coalesce(msg ->> 'role', 'agent') AS role,
               unnest(CASE json_type(msg -> 'content') WHEN 'ARRAY' THEN json_extract(msg, '$.content[*]') ELSE [msg -> 'content'] END) AS block
        FROM recent WHERE msg IS NOT NULL)
  WHERE coalesce(block ->> 'type', 'text') IN ('text', 'input_text', 'output_text')
)
SELECT source, session, transcript, ts, role, text
FROM messages
WHERE len(array_intersect(string_split(lower(text), ' '), ['webbed', 'crawler', 'tera', 'shellfs'])) > 0
ORDER BY ts DESC;
```

## Subagents and forks

A Claude subagent is a file under `<session>/subagents/`; its lines carry `agentId`. A Codex child thread is its
own rollout whose `session_meta` line names its parent:

```sql
WITH meta AS (
  SELECT e.session, l.transcript, l.timestamp ->> '$' AS started_at, l.payload ->> 'id' AS thread_id,
         l.payload ->> 'parent_thread_id' AS parent_thread_id, l.payload ->> 'forked_from_id' AS forked_from_id,
         l.payload ->> 'agent_nickname' AS nickname, l.payload ->> 'cwd' AS cwd
  FROM agent.lines l JOIN agent.entries e ON e.path = l.transcript
  WHERE l.type ->> '$' = 'session_meta'
)
SELECT * FROM meta
WHERE started_at > (now() - INTERVAL 2 DAY)::VARCHAR AND parent_thread_id IS NOT NULL
ORDER BY started_at DESC;
```
