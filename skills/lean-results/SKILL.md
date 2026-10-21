---
name: lean-results
description: Shape a dev query so its result costs fewer context tokens than the Bash call it replaces. Measured so far (2026-10-19, same inputs): DuckDB wins (0.22–0.35×) where the query projects or aggregates a structural answer (read_json projected, read_ast call sites, per-file counts); carrying the same text through read_lines costs 1.02–1.86×. Use before any dev query whose result the agent will read, and to measure real tokens per tool turn from agent.lines usage.
---

# Lean results

Every turn re-sends the whole context, so a result's size is paid on every later turn (Teague Sterling,
judgementalmonad.com, "the round-trip tax"). A DuckDB query only saves tokens when it returns *less than the
text*: a projection, an aggregate, or a parse. As a transport for the same text it costs a little more.

## Measured (verification rows under `~/.duck/agent_log/toolcall_falsification_2026_10_19`)

| question | Bash bytes | DuckDB shape → bytes | ratio |
|---|---|---|---|
| CI jobs of a run | `gh run view` 6,432 | `read_json(gh … --json jobs)` projected name, conclusion, failed steps 1,574 | 0.24× |
| who calls `Project(` | `grep -rnE` 27,531 | `read_ast(…, 'python') WHERE type = 'call'` file + line 9,523 | 0.35× |
| same, per file | 27,531 | one row per file with a count 6,051 | 0.22× |
| definitions in 3 folders | 3 greps, 3 turns, 33,681 | one `read_ast` outline, 1 turn, 35,394 | 1.05× (2 turns saved) |
| git status + log + diff stat | 1,136 | git_log + git_status + git_diff_tree projected 1,310 | 1.15× |
| a file | `cat` 29,242 | `read_text` one row 30,468 | 1.04× |
| lines 1–80 | `sed -n` 3,754 | `read_lines` content only 4,971 / `SELECT *` 16,962 | 1.32× / 4.5× |
| `ps` | 80,931 | `read_lines` content 93,016 / `SELECT *` 150,807 | 1.15× / 1.86× |

Real tokens (agent.lines usage, 3 days to 2026-10-19, single-result turns, ids deduped): a dev SQL turn costs a
median 912 new tokens, a Bash turn 810 (+13%); p90 4,027 vs 2,637 (+53%). Writing the SQL is part of that cost.

## Shape rules

- Ask the structural question: parse (`read_ast`, `parse_ast_list`, `parser_tools`), aggregate per file or per
  key, project the 2–4 columns the next step needs. That is where the savings are.
- Never return `file_path` from `read_lines`/`read_csv` over a command: it repeats the whole command on every row.
  Select `content` (or named columns) only in what comes back to you: `SELECT *` from a reader returned to the
  agent cost 1.86–4.5×. The dispatched statement inside a self-dispatch (`SELECT * FROM <reader>(…)`) is not
  that; project in the outer SELECT over the receipts.
- When you do want the text, take it as one row (`read_text`, a batch read you intend) instead of one JSON row per
  line (+29–57%).
- `EXPLAIN ANALYZE` returns 10–90 KB: read the `latency` only, or don't run it.
- Bound the query before it runs; a result over the MCP's 25k-token limit fails after running, and the retry is
  another full turn.
- Do not re-read an image: four PNGs read 25–27 times each were 154 MB of the Read tool's 244 MB.
- Read a file once: 2,664 of 10,955 text reads were re-reads (ids deduped; setup.sql 41× in 9 sessions). A bounded
  `read_lines` slice is 1.32× the same `sed` slice, so the saving is not re-reading, not the reader.
- A chain of greps is the cost, not one grep: ask the question once as a parse or an aggregate.

## Measure a turn's real tokens

`agent.messages` has no usage columns; the API's `cache_creation_input_tokens + input_tokens` on the next
assistant line is what a result (plus the call that asked for it) added. Count each `tool_use_id` once:
agent.messages still repeats some ids 2–5× in one transcript.

```sql
WITH uses AS (
  SELECT tool_use_id, arg_min(tool_name, line) AS tool_name FROM agent.messages
  WHERE block_type = 'tool_use' AND timestamp > now() - INTERVAL 3 DAY GROUP BY tool_use_id
), first_results AS (
  SELECT tool_use_id, arg_min({'file_path': file_path, 'line': line, 'content_bytes': content_bytes}, line) AS first_result
  FROM agent.messages
  WHERE block_type = 'tool_result' AND timestamp > now() - INTERVAL 3 DAY AND NOT contains(head, '"type":"image"')
  GROUP BY tool_use_id
), results AS (
  SELECT tool_use_id, first_result.* FROM first_results
), usage AS (
  SELECT transcript, file_row_number,
         (message -> 'usage' ->> 'cache_creation_input_tokens')::BIGINT + (message -> 'usage' ->> 'input_tokens')::BIGINT AS new_tokens
  FROM agent.lines
  WHERE type ->> '$' = 'assistant' AND (timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 3 DAY AND NOT contains(transcript, '/.codex/')
), turns AS (
  SELECT results.*, usage.file_row_number AS next_turn, usage.new_tokens
  FROM results ASOF JOIN usage ON results.file_path = usage.transcript AND usage.file_row_number >= results.line + 1
), single AS (
  SELECT file_path, next_turn, array_agg(tool_use_id) AS ids FROM turns GROUP BY ALL HAVING len(ids) = 1
)
SELECT uses.tool_name, len(array_agg(turns.tool_use_id)) AS turns, quantile_cont(turns.new_tokens, 0.5)::INT AS p50_tokens,
       quantile_cont(turns.new_tokens, 0.9)::INT AS p90_tokens, sum(turns.content_bytes) AS result_bytes
FROM turns SEMI JOIN single USING (file_path, next_turn) JOIN uses USING (tool_use_id)
GROUP BY ALL ORDER BY turns DESC LIMIT 7
```

Verified on dev 2026-10-19 (Bash 3,132 turns, dev SQL 5,369). `agent.messages` repeating tool_use_ids is a view
defect to fix in server/messages.sql; until then the `arg_min` per id above is required.

A head-to-head is one agent-log `verification` row with both sides on the same inputs (agent-dispatch §3).
