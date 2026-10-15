---
name: agent-stream
description: Find recent or relevant agent conversations (Claude Code, Codex) from dev's transcript store, then drill into complete messages and tool activity.
allowed-tools: mcp__dev__query
---

# Agent stream

Transcripts are already indexed on dev. Query the `agent.*` views through `mcp__dev__query`. Do not
re-parse the raw JSONL.

## The store

- **Where:** `~/.duck/lake/agent/lines/source=<s>/project=<p>/file_key=<k>/part0.parquet`, plus `events/`.
- **Coverage:** every Claude Code and Codex transcript, including subagents and `.jsonl.zst` rollouts.
- **Feed:** a dev cron runs every minute.
  - It lists files with one shellfs `find`, then hostfs `file_size`/`file_last_modified`.
  - Each changed file's partition is rewritten with one self-dispatched COPY.
  - So the store is about a minute behind live.

| View | One row per |
|---|---|
| `agent.messages` | text block: `source, file, line, idx, session_id, agent_id, ts, role, text` (tool results excluded) |
| `agent.tool_calls` | tool call with its result: `tool_name, input` (JSON), `is_error, error, result_bytes, level` |
| `agent.copies` | call or response id, with `first_seen`. A resumed transcript repeats earlier calls; keep `first_seen` to count each once |
| `agent.sessions` | transcript file: `started_at, cwd, git_branch, is_subagent, parent_session_id, forked_from_id` |
| `agent.usage` | model response with token counts |
| `agent.thinking` | thinking / reasoning-summary block |
| `agent.lines` | raw line: `record` JSON plus typed top-level columns |

The key is `(file, line)`. Roles are `user`/`assistant` for Claude and `user`/`assistant`/`agent` for Codex.
`agent_id IS NULL` keeps top-level sessions and drops Claude subagents.

## Rules

- **One statement covers every session.** Filter by a `ts` window, `file IN (…)` or `(file, line) IN (…)`.
  Never one query per file or per line.
- **Keep rows.**
  - No `QUALIFY row_number() = 1` dedup and no `left()` cuts.
  - Size text with `strlen`.
  - Pick a row with an ASOF join or `arg_max`.
  - Dedup copies with `agent.copies.first_seen`.
- **Oversized results:** when a result is too big for the tool, it is saved as JSON under the session's
  `tool-results/`. Query that file with `read_json('<file>')`; don't re-run the query.
- **Briefs:** a subagent brief names the view and the query below. Never point it at a store root.
- **agent_data:** `read_conversations` is only for one file the store doesn't hold yet, with
  `path := '<that file>'`. Never point it at `~/.claude` or `~/.codex`.

## Turns: each prompt and the reply that closed it

Each prompt pairs with the last assistant text before the next prompt. `reply IS NULL` means no reply yet.

```sql
WITH prompts AS (
  SELECT source, file, line, ts, session_id, text AS prompt,
         lead(line) OVER (PARTITION BY file ORDER BY line) AS next_prompt_line
  FROM agent.messages
  WHERE role = 'user' AND agent_id IS NULL AND ts > now() - INTERVAL 2 DAY
    AND NOT starts_with(ltrim(text), '<')                       -- harness tags, reminders
    AND NOT starts_with(text, 'This session is being continued') -- compaction summaries
), replies AS (
  SELECT file, line AS reply_line, text AS reply
  FROM agent.messages
  WHERE role IN ('assistant', 'agent') AND agent_id IS NULL AND ts > now() - INTERVAL 2 DAY
), turns AS (
  SELECT p.*, CASE WHEN r.reply_line > p.line THEN r.reply_line END AS reply_line,
              CASE WHEN r.reply_line > p.line THEN r.reply END AS reply
  FROM prompts p
  ASOF LEFT JOIN replies r ON r.file = p.file AND r.reply_line < coalesce(p.next_prompt_line, 9223372036854775807)
)
SELECT source, session_id, file, line, ts, prompt, reply_line, reply FROM turns ORDER BY session_id, line;
```

**One row per session.** This shows where each session stands. The final reply usually lists what it is
waiting on.

```sql
-- same CTEs as above, then:
SELECT source, session_id, arg_max(ts, line) AS last_ts,
       arg_max(prompt, line) AS last_prompt, arg_max(reply, line) AS last_reply
FROM turns GROUP BY source, session_id ORDER BY last_ts DESC;
```

## External actions: PRs, issues, comments, pushes, forks

```sql
WITH actions(action, words) AS (VALUES
  ('pr create', ['gh', 'pr', 'create']), ('pr comment', ['gh', 'pr', 'comment']), ('pr close', ['gh', 'pr', 'close']),
  ('pr merge', ['gh', 'pr', 'merge']), ('pr edit', ['gh', 'pr', 'edit']), ('issue create', ['gh', 'issue', 'create']),
  ('issue comment', ['gh', 'issue', 'comment']), ('fork', ['gh', 'repo', 'fork']), ('push', ['git', 'push'])
), calls AS (
  SELECT t.source, t.level, t.session_id, t.file, t.line, t.ts, t.tool_name, t.is_error,
         coalesce(t.input ->> 'command', t.input ->> 'cmd', t.input ->> 'sql', t.input::VARCHAR) AS cmd
  FROM agent.tool_calls t
  SEMI JOIN agent.copies c ON c.kind = 'tool_call' AND c.id = t.call_id AND c.file = t.file AND c.line = t.line AND c.first_seen
  WHERE t.ts > now() - INTERVAL 2 DAY
)
SELECT a.action, c.* FROM calls c JOIN actions a ON list_has_all(string_split(replace(c.cmd, '''', ' '), ' '), a.words)
ORDER BY c.ts;
```

The words match anywhere in the tool input. A call that only mentions `gh pr create`, such as a search or
a heredoc, also matches, so read `cmd`. Codex logs both the model's call (`level = 'model'`) and the
command it ran (`level = 'nested'`).

## Plans

```sql
SELECT 'tool' AS via, source, session_id, file, line, ts, tool_name AS what, input::VARCHAR AS plan
FROM agent.tool_calls
WHERE ts > now() - INTERVAL 2 DAY AND tool_name IN ('ExitPlanMode', 'update_plan', 'TodoWrite')
UNION ALL BY NAME
SELECT 'message' AS via, source, session_id, file, line, ts, 'proposed_plan' AS what, text AS plan
FROM agent.messages
WHERE ts > now() - INTERVAL 2 DAY AND role IN ('assistant', 'agent') AND starts_with(ltrim(text), '<proposed_plan>')
ORDER BY ts;
```

## Search

Keep the terms as an array and intersect tokens, rather than chaining text predicates:

```sql
SELECT source, session_id, file, line, ts, role, text
FROM agent.messages
WHERE ts > now() - INTERVAL 7 DAY
  AND len(array_intersect(string_split(lower(text), ' '), ['webbed', 'crawler', 'tera', 'shellfs'])) > 0
ORDER BY ts DESC;
```

## Subagents and forks

`agent.sessions` carries `is_subagent`, `parent_session_id` and `forked_from_id`. Claude subagent rows in
`agent.messages` have an `agent_id`. Codex children carry their parent in `parent_session_id`.
