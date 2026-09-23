---
name: agent-dispatch
description: >
  Use before fanning work out to subagents in this user's repos. Encodes his written
  orchestration practices (private repo asubbarao/devx-takeaways, agent-orchestration/)
  as a dispatch packet plus the house rules every worker must carry: Opus 5.5 set
  explicitly unless a model is named (say which and why), no .sh or Python in the data path
  (shellfs inside .sql), regex only on web and log text, no selector-taking extractors, no
  lossy aggregation, and evidence that is false-first and read from CI/GitHub. Covers
  launch-evidence-before-promotion, write-scope as an enforcement boundary, bounded rounds,
  and recombination.
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

**One worker is one git worktree on one branch of one repo.** `worktree_path` is a
`git worktree add -b <worker-branch> <path> origin/<base>` path, never a second `git clone`
— including for someone else's repo. A fresh worktree has submodules uninitialised; run
`git submodule update --init --depth 1 --recursive` in it before dispatch, so the worker can
build and run the suite instead of returning an untested patch. Give every worker its own
branch name: worktrees share one branch namespace, and parallel workers given the same name
collide. For Codex, launch with `-C <worktree>` (verified: it can branch and commit there;
in a full clone `.git` is read-only) — see the codex skill's Worktrees section.

`write_scope` is an **enforcement boundary**, not documentation: a worker with no
declared boundary silently edits central files. Classify honestly — two workers on
one file is `overlap-risk`, and the merge order gets named up front.

Bound every loop. Max rounds, a repeat-failure cap, and a small set of explicit
terminal statuses. `pending` and `awaiting` are never terminal.

## Which model does the work

**Claude subagents: Opus 5.5, set explicitly** — `model: "opus"` on every `Agent` call. Never
leave it unset (the worker then inherits whatever the session was switched to), and never pick
Sonnet or Haiku on your own for "scoped" work or searches. The owner overrides by naming a model
("send a sonnet", "send a fable"). The one standing exception, his words: a *highly
parallelizable* fan-out of small, identical, mechanical reads — one worker per folder, per repo,
per month — goes to Sonnet, and the merge of what they return stays with Opus. The test is the
shape of the task, not its importance; anything with judgement in it is Opus.

**Always say which model you sent and why**, in the dispatch message and in the report ("Opus
5.5 — the analysis needs judgement"). A model is a stated decision, never an accident of timing.

Codex models, ranked by the owner against the Claude models — pick by the difficulty of the task:

| model | sits | use for |
|---|---|---|
| `luna` | the workhorse | fix a specified bug, or do a specified thing. One task per dispatch |
| `terra` | between sonnet and opus | routine implementation from a design that already exists |
| `sol` | between opus and fable | design, adversarial review of a diff, a plan, "what would you do next" |
| `astra` | just short of fable | expensive; only when the owner names it |

A named defect with a reproduction goes to luna. Sol reviews the diff luna or terra produces before
anything is committed. See `/codex` for the exact `-m` identifiers and the sandbox flags.

## 3. House rules every brief carries, at full strength

State these as the end state, never as "do not *add* one" — softening a rule into a
property of the diff blesses every existing violation.

- **No `.sh` files.** Bash a pipeline needs lives in a template string inside the
  `.sql` and runs through shellfs: `read_csv('bash -c ''…'' |')`. Stream with
  `read_csv` / `read_json`, batch with `read_text` / `read_blob`. Pass `read_csv`
  parameters explicitly — `delim`, `header`, `columns`/`names`, `types`, `quote` —
  and never leave a `column0`. The only legitimate shell artifact is a daemonizing
  plist. Starting a server for the length of a measurement is pipeline, not daemon.
- **Regex: allowed on web pages and log lines, banned on backend queries.** Unstructured text
  from outside — a fetched page, a CI or tool log (duck_hunt's `regexp:` format) — may be
  matched with a regex; say so in one line. Anything structured (paths, hive keys, JSON,
  timestamps) and any query against a backend database (Postgres in any environment, the app's
  CRUD code, DuckDB over structured backend data) stays `regexp_*`-free without his explicit
  approval. **No selector-taking extractors**
  (`json_extract`, `html_extract_text(doc,'//path')`) in committed code — readers
  only; mechanical test is positional arity ≥ 2 in `duckdb_functions()`.
- **No `COUNT(*)`, `min`, `max`, `avg`.** `array_agg(DISTINCT c) AS cs, len(cs) AS n`.
- **No enumeration** — no `split_part`, no positional indexing of structure.
- One `.sql` per deliverable, built a layer at a time. No macros yet. **No Python and no
  `.sh` in the data path** — fetch through shellfs, parse with readers, render with tera. A
  scratch script a worker writes to get unstuck is removed before it reports (inside its
  worktree; anywhere else it is listed for the main agent), and the deliverable must not
  depend on it. Python outside the data path only where genuinely needed,
  through `uv` (`uvx …`), never a hand-built venv.
- **A name in backticks is an extension**: `INSTALL <name> FROM community; LOAD <name>;` in the
  worker's own `:memory:` client is always allowed — say so in the brief.
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
restored passing output.

**Evidence a teammate may see comes from CI and GitHub, not from this laptop.** Timing,
test health and PR verification read GitHub Actions runs, jobs and steps (`gh run list/view
--json` through shellfs — `/duckstack:ci-timing`) and the PR's own checks. A query over local
logfiles, session transcripts or a `pytest | tail` capture cannot be handed to anyone; local
runs are for iteration only. "Not null" and "length > 0" are not assertions. Quality
gates run in a context that cannot silently edit what it reviews.

## 5. Recombination is routine

If each branch works alone, merging is ordinary work for one agent — split by file
set, commit each coherent change, build, run the suite. Escalate only a genuine
semantic clash. Do not report difficulty in place of doing the merge, and do not
resolve with a blanket `--ours`/`--theirs`.

Shared files are named once, up front, and owned by the merging agent — test-count
constants and generated headers especially, where N workers editing one file is N
conflicts over arithmetic. Recompute those by measurement, never by addition.
