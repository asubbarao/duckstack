---
name: agent-stream
description: Find recent or relevant agent conversations (Claude Code, Codex) from dev's transcript store, then drill into complete messages and tool activity.
allowed-tools: mcp__dev__query
---

# Agent stream

Start from `agent.messages`: one row per message block, agent_data's column names (`source, session_id, file_path,
line, block_index, block_key, is_agent, timestamp, message_role, block_type, tool_name, tool_use_id, uuid, model, cwd,
git_branch, entrypoint`), plus `is_prompt` (a person's typed message), `content_bytes`, and `head`/`tail` (first and
last 100 characters) and `tool_command_head` in place of the full text, so a 290 KB paste never fills a reply. List there; search with the
query under Search. The full text of a row you picked is `stream.blocks.message_content` on the same `block_key`.
A resumed session repeats lines under the same `uuid`; `is_repeat` marks those copies, so filter `NOT is_repeat`.
Never unpack `agent.lines` JSON by hand, never `read_conversations`, and never read `lake.agent.stream` (stale since
2026-10-09).

```sql
SELECT timestamp, session_id, content_bytes, head, tail FROM agent.messages
WHERE is_prompt AND timestamp > now() - INTERVAL 3 DAY ORDER BY timestamp;
```

Turns, actions and plans read `stream.blocks` (full text, `tool_input`, and `tool_command`: the input's command,
cmd or sql, else the whole input). The raw store below is for fields neither carries (`session_meta`, payload extras).

## The store

- **Where:** one Parquet per session under `~/.duck/lake/agent`, at the session's own path
  (`~/.duck/lake/agent/Users/<you>/.claude/projects/<project>/<session>.parquet`, Codex rollouts likewise).
- **Coverage:** every Claude Code and Codex transcript. A Claude session's Parquet holds its main file and its
  `subagents/*.jsonl`.
- **Feed:** boot and a cron every 5 minutes copy each session whose transcript changed since its stored copy, then
  re-post `agent.lines` over the stored files. So the store is up to ~5 minutes behind live; `stream.blocks` refreshes
  every 15 minutes on top of it.

| View | One row per |
|---|---|
| `agent.entries` | transcript file or stored Parquet: `path, parent, name, stem, ext, bytes, modified, reader, session` |
| `agent.lines` | transcript line: every top-level field as a `JSON` column, plus `transcript` (the source file's path) |

- `session` (from `agent.entries`) is the session's path without extension; join `agent.entries e ON e.path = l.transcript`.
  Claude subagent files share their parent's `session`; `contains(transcript, '/subagents/')` marks them.
  Each Codex thread is its own session.
- `(timestamp ->> '$')::TIMESTAMPTZ` is the line's time. `file_row_number` is the line's row in its stored file, so
  (`transcript`, `file_row_number`) is unique.
- If a filter on several `payload` fields fails with `Failed to cast value to numerical`, project them as columns
  in one CTE and filter in the next.

## Rules

- **One statement covers every session.** Filter by a time window, `file_path IN (…)` or `session_id IN (…)`.
  Never one query per file.
- **Keep rows.** No `QUALIFY row_number() = 1` dedup and no `left()` cuts; size text with `strlen`; pick a row with an
  ASOF join or `arg_max`; drop resumed copies with `NOT is_repeat`.
- **Oversized results:** when a result is too big for the tool, it is saved as JSON under the session's
  `tool-results/`. Query that file with `read_json('<file>')`; don't re-run the query.
- **Briefs:** a subagent brief names `agent.messages` or `stream.blocks` and the query below. Never a store root.
- **agent_data:** `read_conversations` is only for one file the store doesn't hold yet, with
  `path := '<that file>'`. Never point it at `~/.claude` or `~/.codex`.

## Now: what every session is doing

Start here when asked about "the chat", "a session" or anything happening right now. Concurrent sessions
include other terminals and Claude Desktop. One row per session active in the last hour: its title, branch, the
PRs it linked, minutes idle, and the other live sessions that share its branch or one of its PRs. Two sessions on
one branch, or one PR, are about to collide. It reads only top-level fields: no message text.

```sql
WITH session_lines AS (
  SELECT sessionId ->> '$' AS session_id, (timestamp ->> '$')::TIMESTAMPTZ AS ts,
         gitBranch ->> '$' AS branch, coalesce(customTitle ->> '$', aiTitle ->> '$') AS title,
         prRepository ->> '$' || '#' || prNumber ->> '$' AS pr
  FROM agent.lines
  WHERE NOT contains(transcript, '/subagents/') AND NOT contains(transcript, '/.codex/')
), live_sessions AS (
  SELECT session_id, max(ts) AS last_ts FROM session_lines GROUP BY session_id HAVING max(ts) > now() - INTERVAL 1 HOUR
), per_session AS (
  SELECT s.session_id, l.last_ts, list_distinct(list(s.title)) AS titles, arg_max(s.branch, s.ts) AS branch,
         list_distinct(list(s.pr)) AS prs
  FROM session_lines s JOIN live_sessions l USING (session_id) GROUP BY s.session_id, l.last_ts
), touches AS (
  SELECT session_id, 'branch ' || branch AS thing FROM per_session WHERE branch <> 'staging'
  UNION ALL
  SELECT session_id, unnest(prs) AS thing FROM per_session
), shared AS (
  SELECT a.session_id, list_distinct(list(b.session_id || ' ' || a.thing)) AS shares_with
  FROM touches a JOIN touches b ON a.thing = b.thing AND a.session_id <> b.session_id
  GROUP BY a.session_id
)
SELECT p.session_id, p.titles, p.branch, p.prs, date_diff('minute', p.last_ts, now()) AS idle_min, s.shares_with
FROM per_session p LEFT JOIN shared s USING (session_id) ORDER BY p.last_ts DESC;
```

- `titles` lists every title the session has had: title lines carry no timestamp.
- `prs` holds only the PRs Claude Code recorded as linked; a PR opened through dev's shellfs isn't one.
- `staging` is the shared checkout's branch, so it isn't counted as an overlap.
- Claude sessions only: Codex keeps its branch under `payload.git` of its `session_meta` line, not at the top level.

## Turns: each prompt and the reply that closed it

Each prompt pairs with the last assistant text before the next prompt. `reply IS NULL` means no reply yet.

```sql
WITH messages AS (
  SELECT b.source, b.session_id, b.file_path, b.timestamp AS ts, b.is_agent, b.is_prompt, b.message_role, b.message_content
  FROM stream.blocks b
  WHERE NOT b.is_repeat AND b.block_type IN ('text', 'input_text', 'output_text') AND b.timestamp > now() - INTERVAL 2 DAY
), prompts AS (
  SELECT source, session_id, file_path, ts, message_content AS prompt,
         lead(ts) OVER (PARTITION BY file_path ORDER BY ts) AS next_prompt_ts
  FROM messages WHERE is_prompt
), replies AS (
  SELECT file_path, ts AS reply_ts, message_content AS reply FROM messages WHERE message_role = 'assistant' AND NOT is_agent
), turns AS (
  SELECT p.*, CASE WHEN r.reply_ts > p.ts THEN r.reply_ts END AS reply_ts,
              CASE WHEN r.reply_ts > p.ts THEN r.reply END AS reply
  FROM prompts p
  ASOF LEFT JOIN replies r ON r.file_path = p.file_path AND r.reply_ts < coalesce(p.next_prompt_ts, 'infinity'::TIMESTAMPTZ)
)
SELECT source, session_id, ts, prompt, reply_ts, reply FROM turns ORDER BY session_id, ts;
```

**One row per session.** This shows where each session stands. The final reply usually lists what it is
waiting on.

```sql
-- same CTEs as above, then:
SELECT source, session_id, max(ts) AS last_ts, arg_max(prompt, ts) AS last_prompt, arg_max(reply, ts) AS last_reply
FROM turns GROUP BY source, session_id ORDER BY last_ts DESC;
```

## External actions: PRs, issues, comments, pushes, forks

```sql
WITH actions AS (
  SELECT unnest([{action: 'pr create', words: ['gh', 'pr', 'create']}, {action: 'pr comment', words: ['gh', 'pr', 'comment']},
                 {action: 'pr close', words: ['gh', 'pr', 'close']}, {action: 'pr merge', words: ['gh', 'pr', 'merge']},
                 {action: 'pr edit', words: ['gh', 'pr', 'edit']}, {action: 'issue create', words: ['gh', 'issue', 'create']},
                 {action: 'issue comment', words: ['gh', 'issue', 'comment']}, {action: 'fork', words: ['gh', 'repo', 'fork']},
                 {action: 'push', words: ['git', 'push']}], recursive := true)
), calls AS (
  SELECT b.source, b.session_id, b.file_path, b.timestamp AS ts, b.is_agent, b.tool_name, b.tool_command AS cmd
  FROM stream.blocks b
  WHERE NOT b.is_repeat AND b.block_type IN ('tool_use', 'function_call', 'custom_tool_call') AND b.timestamp > now() - INTERVAL 2 DAY
)
SELECT a.action, c.* FROM calls c
JOIN actions a ON list_has_all(string_split(translate(c.cmd, '''";{}()|&', '         '), ' '), a.words)
ORDER BY c.ts;
```

The words match anywhere in the tool input. A call that only mentions `gh pr create`, such as a search or
a heredoc, also matches, so read `cmd`. Codex's `exec` tool takes JavaScript that calls
`tools.exec_command({cmd: …})`, so its `cmd` is that script.

## Plans

```sql
SELECT 'tool' AS via, source, session_id, file_path, timestamp, is_agent, tool_name AS what, tool_input::VARCHAR AS plan
FROM stream.blocks
WHERE NOT is_repeat AND timestamp > now() - INTERVAL 2 DAY AND tool_name IN ('ExitPlanMode', 'TodoWrite', 'mcp__ccd_turn__update_plan', 'update_plan')
UNION ALL BY NAME
SELECT 'message' AS via, source, session_id, file_path, timestamp, is_agent, 'proposed_plan' AS what, message_content AS plan
FROM stream.blocks
WHERE NOT is_repeat AND timestamp > now() - INTERVAL 2 DAY AND message_role = 'assistant' AND starts_with(ltrim(message_content), '<proposed_plan>')
ORDER BY timestamp;
```

## Search

Pick sessions from `agent.sessions` (one row each, every column carried: activity, files, models, tools, cwd, branch,
`prompts` as whole rows, `first_prompt`, `last_prompt`; select the columns you need, since `prompts` is big), then read their
blocks by `session_id`. To find blocks by words, BM25 over `stream.blocks` (rebuilt every 15 minutes from transcripts
changed in the last 30, on a store up to 5 minutes behind, so up to ~20 minutes behind live):

```sql
SELECT session_id, block_key, timestamp, content_bytes, score
FROM (SELECT *, stream.fts_main_blocks.match_bm25(block_key, 'ohad uploaded documents') AS score FROM stream.blocks)
WHERE score IS NOT NULL ORDER BY score DESC LIMIT 20;
```

## Subagents and forks

A Claude subagent is a file under `<session>/subagents/`; its lines carry `agentId`. A Codex child thread is its
own rollout whose `session_meta` line names its parent (the raw store: `stream.blocks` has no `session_meta`):

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
