---
name: agent-dispatch
description: >
  Use before fanning work out to subagents in this user's repos. Encodes his written
  orchestration practices (private repo asubbarao/devx-takeaways, agent-orchestration/)
  as a dispatch packet plus the house rules every worker must carry: no .sh files
  (shellfs inside .sql), no regexp, no selector-taking extractors, no lossy aggregation,
  and evidence that is false-first. Covers launch-evidence-before-promotion, write-scope
  as an enforcement boundary, bounded rounds, and recombination.
---

# Dispatching agents in Alok's repos

Read this before spawning workers. The source of truth is his private repo
`asubbarao/devx-takeaways` under `agent-orchestration/` — `gh auth switch --user
asubbarao` first, or private repos read as nonexistent under the work account.

## 1. A launch is not a worker

**A returned agent id you never verified is not evidence.** Nor is a PID, a "still
running" message, a branch, or a worktree. Promote a worker to active only on:

- a parseable worker state file on disk, or
- a parseable terminal handoff, or
- a continuation handle the parent can actually poll, wait on or resume.

A tool-router error, malformed spawn args or a later `not_found` is a **launch
failure**: record it, leave the active set unchanged, put the unit back to pending.
A terminal handoff on disk always dominates live-process evidence.

## 2. Dispatch a packet, not prose

One bounded packet per worker. Summaries plus pointers — never the full transcript,
log or diff.

```json
{
  "unit_id": "", "worker_kind": "",
  "acceptance_criteria": [], "parent_constraints": [],
  "repo": "", "base": "", "worktree_path": "", "branch": "",
  "write_scope": {
    "classification": "disjoint-known|disjoint-reviewed|shared-read-only|overlap-risk|unknown",
    "paths": [], "notes": ""
  },
  "summaries": { "source_summary": "", "verification_expectations": [] },
  "stop_conditions": ["write-scope violation", "unsafe op", "source conflict"],
  "output_contract": { "required": ["commit sha", "files changed", "false-first evidence"] },
  "bounds": { "max_rounds": 3, "repeat_failure_cap": 2 }
}
```

`write_scope` is an **enforcement boundary**, not documentation: a worker with no
declared boundary silently edits central files. Classify honestly — two workers on
one file is `overlap-risk`, and the merge order gets named up front.

Bound every loop. Max rounds, a repeat-failure cap, and a small set of explicit
terminal statuses. `pending` and `awaiting` are never terminal.

## 3. House rules every brief carries, at full strength

State these as the end state, never as "do not *add* one" — softening a rule into a
property of the diff blesses every existing violation.

- **No `.sh` files.** Bash a pipeline needs lives in a template string inside the
  `.sql` and runs through shellfs: `read_csv('bash -c ''…'' |')`. Stream with
  `read_csv` / `read_json`, batch with `read_text` / `read_blob`. Pass `read_csv`
  parameters explicitly — `delim`, `header`, `columns`/`names`, `types`, `quote` —
  and never leave a `column0`. The only legitimate shell artifact is a daemonizing
  plist. Starting a server for the length of a measurement is pipeline, not daemon.
- **No `regexp_*`** without his explicit approval. **No selector-taking extractors**
  (`json_extract`, `html_extract_text(doc,'//path')`) in committed code — readers
  only; mechanical test is positional arity ≥ 2 in `duckdb_functions()`.
- **No `COUNT(*)`, `min`, `max`, `avg`.** `array_agg(DISTINCT c) AS cs, len(cs) AS n`.
- **No enumeration** — no `split_part`, no positional indexing of structure.
- One `.sql` per deliverable, built a layer at a time. No macros yet. Python only
  where genuinely needed, run through `uv` (`uvx …`), never a hand-built venv.
- **Delete nothing outside your own worktree** — list it for the main agent.
- Nothing pushed, no PR, nothing another human can see, without his approval.
- Never `-init` against DuckDB; it replaces `~/.duckdbrc`. Never `SET`/`INSTALL`/
  `LOAD` against the dev quack.
- Crude-oil repos are material to read, never services to depend on.

## 4. Evidence is false-first

A guard nobody has seen fail is not a guard, and **he does not accept assertion
counts as evidence of anything** — a total is evidence of exactly one thing: that a
file aborted early, if it drops.

Every worker returns, per claim: the mutant applied, the failing output, the
restored passing output. "Not null" and "length > 0" are not assertions. Quality
gates run in a context that cannot silently edit what it reviews.

## 5. Recombination is routine

If each branch works alone, merging is ordinary work for one agent — split by file
set, commit each coherent change, build, run the suite. Escalate only a genuine
semantic clash. Do not report difficulty in place of doing the merge, and do not
resolve with a blanket `--ours`/`--theirs`.

Shared files are named once, up front, and owned by the merging agent — test-count
constants and generated headers especially, where N workers editing one file is N
conflicts over arithmetic. Recompute those by measurement, never by addition.
