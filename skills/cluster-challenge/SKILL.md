---
name: cluster-challenge
description: Try to disprove "a cluster of Bash calls can always be made faster, cheaper in tokens and fewer in turns as one relational DuckDB query (shellfs + self-dispatch)". The agent must first build the best relational execution of a real cluster, then measure both on the same inputs; a counterexample counts only after every move below was tried. Use when judging Bash vs DuckDB, when a session's calls look like a batch, or when asked to "prove the query beats the calls".
---

# Cluster challenge

**H (Alok, 2026-10-19):** it is always possible to make a cluster of Bash tool calls more performant, more
efficient and fewer tokens as a relational DuckDB query with shellfs and self-dispatch.

Your job is to disprove H — honestly. You may only call a cluster a counterexample after you built the best
relational execution of it and it still loses. A loss with a move left untried is your failure, not H's.

## 1. Cluster first (calls, not single calls)

Episodes per transcript: a new episode after a gap > 2 min or when the arm changes (DuckDB/MCP vs not). Signature
per call with sitting_duck: Bash `parse_ast_list(cmd, 'bash')` `command` nodes (program + git subcommand); SQL
`parse_ast_list(cmd, 'sql')` `invocation` nodes (readers, git_*, selfdispatch), plus the shell commands inside its
`'… |'` literals parsed as bash. Real cost per call: the next assistant line's `message.usage` in agent.lines
(ASOF JOIN on transcript, `file_row_number >= result line + 1`). Ids repeat in the stream: one row per
tool_use_id with `arg_min(…, line)`. The query: [references/clusters.sql](references/clusters.sql).

## 2. Reverse-engineer the questions

Read the cluster's commands in order and the assistant text right after it. Write the distinct questions it was
answering and which results it actually used. The rewrite must answer those, not the commands.

## 3. Build the best relational execution — every move, tried or ruled out with a reason

1. **One statement, wide inside, narrow out.** Columns are free inside a CTE (keys, paths, hashes, derived arrays,
   joins to existing dev views); tokens are spent only on the final SELECT. Project what the next step uses.
2. **Structure, not text.** `read_ast`/`parse_ast_list` (sitting_duck) for code, `parser_tools` for SQL,
   `read_json` over `gh … --json <fields>` projected, `duck_hunt` for logs, `duck_tails`/git commands for history,
   `fs.files` for find/ls, `fts` BM25 for search, `rapidfuzz` for near-duplicates.
3. **Filter at the source.** Pathspecs, `--json` field lists, per-depth globs, WHERE before the reader returns.
4. **Aggregate before returning.** Per file, per key, lists instead of rows when the question is "which/where".
5. **Per-row commands are self-dispatched.** Atom `array_agg(selfdispatch(tera_render($t$…$t$, row::JSON,
   autoescape := false)))`, molecule `UNNEST(receipts) … UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)`.
   Each statement selects its own keys. Never a LATERAL table function, never matching receipts to inputs by
   array position.
6. **Stream.** `read_csv`/`read_json`/`read_lines` over a command; `read_text` only for an intended one-blob read.
   Never return `file_path` from a command reader, never `SELECT *`, never EXPLAIN output.
7. **One turn.** Questions the cluster asked across turns go in one statement (UNION ALL BY NAME of shaped
   answers, or one wide relation).

## 4. Measure both on the same inputs

| side | turns | bytes received | wall time |
|---|---|---|---|
| cluster (from the transcript) | its turns | its result bytes; real new tokens from usage | its span |
| best rewrite (run now) | 1 | SQL bytes + MCP JSON result bytes | latency |

Log one agent-log `verification` row with both sides (agent-dispatch §3 COPY shape), skill `cluster-challenge`.

## 5. Verdict

- **H holds for the cluster** when the rewrite answers the same questions with fewer tokens and fewer turns.
- **Counterexample** only when the best rewrite still loses on tokens *and* turns or time, with every move in §3
  tried. Report what blocked it as a defect to fix — a missing function or extension, a hook, the 2-min deadline,
  the MCP result ceiling — never as a reason to prefer Bash.
- A rewrite that answers fewer questions does not count either way.

Measured shapes and real-token numbers so far: [../lean-results/SKILL.md](../lean-results/SKILL.md).
