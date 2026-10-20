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
7. **One turn.** Questions the cluster asked across turns go in one statement. Return each answer as
   `(question, lines[])` rows from UNION ALL; a wide UNION ALL BY NAME pads every row with NULL columns. When the
   answer is long text, split it near 49 KB per call and send the calls in parallel in the same turn (the MCP result
   ceiling is 25k tokens).
8. **Same inputs.** Pin code to commit shas (`git://…@sha`, `git_tree`) taken from the episode's own output; a
   `--before` date can pick a merged-in commit.

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

## Results (2026-10-19, rows under `~/.duck/agent_log/toolcall_falsification_2026_10_19`, agents `opus-challenge-a`, `-c`)

| episode | real cost (API turns / new tokens) | best rewrite | bytes | time |
|---|---|---|---|---|
| git/gh status of 3 branches + prompt history (27 calls) | 8 / 129,027 | 1 turn, 5 parallel calls | 0.68× | 122 s → 2.4 s |
| tool-call store analysis (38 calls, 9 failed) | 8 / 65,098 | 1 turn, 2 calls | 0.25× | 500 s → 56 s |
| hook-rule work: reads + check (39 calls) | 23 / 164,958 | 3 turns (read, edit, verify) | 0.27× of the query part | — |
| security review of a branch (37 calls, 33 Reads) | 9 / 179,027 | 4 turns: changed functions ⋈ call graph 2 hops | 0.63× | 85 s → 4.1 s |
| 3 parallel rule-mining agents (49 calls) | 41 / 740,641 | 15 turns: dedupe, drop relays, page by bytes | 0.61× | — |
| model + migration build, read side (27 of 65 calls) | 21 / 86,605 | 1 turn, 2 parallel calls | 0.89× tokens | 178 s → 3.8 s |
| sync + 25 whole files + Linear sections, read side (51 of 112 calls) | 28 / 126,387 | 2 turns | 0.93× tokens | 180 s → 4.3 s |

H held in all seven. When most bytes are whole files the agent edits from verbatim, H wins through turns and
time, not tokens (~0.9×). What kept it from one turn: the MCP result ceiling whenever the model must read the text
itself (reviews, mining) — there turns ≈ bytes ÷ the ceiling for Read and SQL alike, so DuckDB wins by sending
fewer bytes (diff-scope to changed functions, call-graph context, dedupe, drop relays and code fences); and a gate
file that `.read`s other files instead of being one CTE query.

Defects found (fix them; they are not reasons to prefer Bash): `read_ast` cannot read a shellfs pipe
(DirectoryExists not implemented); `git://`/`git_tree` need a commit, so a mid-merge tree is rebuilt from the three
trees plus `git merge-tree`; `read_csv` over a command with empty output fails sniffing; `git grep` through shellfs is
hook-blocked while a full `read_text` scan of the tree read 34 MB in ~3 s.

Cautions from these runs: a multi-stage pipeline that `TRY_CAST`s receipts must also select `receipt.status` and
`receipt.error` (a hop returned nothing silently); a dispatched statement whose only column is `text` comes back as
a bare value and `TRY_CAST(… AS JSON[])` drops it — select a key column beside it. Real cost is keyed on
`message.id`; clusters.sql's next-turn sum still runs ~1.3× high on parallel-call episodes, so recount an episode's
responses by `message.id` over its span before a verdict.

Measured shapes and real-token numbers so far: [../lean-results/SKILL.md](../lean-results/SKILL.md).
