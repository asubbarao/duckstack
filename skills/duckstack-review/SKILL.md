---
name: duckstack-review
description: Harsh code-style and efficiency review of DuckDB SQL work (a PR, a branch, a .sql file, an agent's pipeline, a skill's examples). Use whenever SQL, a self-dispatch pipeline, a tera template, a dev server file or a duckstack skill is about to be committed or merged, or when asked to review "the SQL", "the pipeline", "the duckdb part" or "is this elegant". Assumes the change is poorly written until the code proves otherwise. Checks self-dispatch first, because missing self-dispatch is the most common failure and the cause of slow, crashing work.
---

# duckstack review

The agents who wrote this tried their best, and everything they wrote is still a SQL
antipattern until the code proves otherwise: not self-dispatching, procedural instead of
set-based, built from strings, wrapped in macros, and missing the shared relation that would
have helped everyone. The review's job is to find where. A clean verdict needs evidence from the
code, never a lack of objections.

The full catalogue of antipatterns is the owner's own messages in the agent stream: every time
he corrected an agent's SQL, he named the antipattern and why. Read them before reviewing. On
dev, take his typed prompts only (`agent.lines`, user turns, entrypoint `cli` or
`claude-desktop`, no subagent files, plus Codex `vscode`/`cli` sessions), join a relation of
terms (declarative, set-based, self-dispatch, relation, macro, tera, loop, readable, slow, and
the angry ones), and pair each hit with the assistant message just before it to see what was
done wrong. Keep the read bounded: by time window or by session files, never a full scan of
`agent.stream` (one took dev down). The checks below are that catalogue as of 2026-10-17,
ranked by how often he raised each.

This is a style and efficiency review. Correctness bugs go to `/code-review`; here, a query
that works but is ugly, slow or unreusable is a finding. The contract is
[SQL-MANIFESTO.md](../../SQL-MANIFESTO.md); read it first.

## Checks, in order of how often agents fail them

Report every hit with file:line, the rule, and the rewrite.

The baseline: a query under ~50 lines that has no bash loop, no tera loop or conditional, and no
pile of new tables or views is assumed good. Self-dispatch is the usual shape, not a requirement.
Spend the review on what breaks that baseline.

### 1. Self-dispatch, or the lack of it (the main failure)

Self-dispatch is `array_agg` of posts to self, then `CROSS JOIN UNNEST` of the receipts.
It removes binder limits, keeps a pipeline to one query, and runs rows together.
Across a month of transcripts this was the owner's most repeated complaint, and the root of most
"why is this so slow" and "why did it crash" moments.

Flag:
- A lateral join on a table function, a `read_*_lateral`, a column passed into `read_csv` or
  `read_text`, or a comment explaining a binder error away ("only accepts a literal"). A binder
  error means: self-dispatch.
- A `UNION ALL` of N hand-written statements, one per input.
- A bash loop, `xargs`, a `.sh` file or a Python loop that runs one command per row.
- An inputs-times-endpoint cross join, listener discovery joined into the dispatch, or any
  cross join that is not `CROSS JOIN UNNEST(array)`.
- A `COPY` wrapped around the outer dispatch when it belongs inside each generated statement.
- Dispatch hidden in a macro tower or a tera template instead of visible in the query.
- Session variables set in one statement and read back in the next to pass values along.

Measure, don't guess: a pipeline that takes minutes or holds gigabytes is a finding even when it
returns the right rows. Check `EXPLAIN` and how many rows move; pruning and predicate pushdown
only work when each dispatched statement is narrow.

### 2. Data path outside SQL

Flag Python, `.sh` files, `jq`, `grep`, `find`, `sed` or `awk` doing work SQL could do. Files are
read with readers (`read_text`, `read_lines`, hostfs `ls`/`lsr`), commands through shellfs with
explicit `read_csv` options and no unnamed `column0` left behind. Python appears only in the
smallest amount that feeds more DuckDB, run through self-dispatch. A change that replaces Python
should be a fifth to a tenth of its length.

### 3. Macros where a view and a WHERE would do

Every new macro is a finding unless it is a true primitive the owner already approved. "Why a
parameter? Can't you use a WHERE clause on the view?" No construction macros, no dispatch
macros, no `macro(macro(...))`, no cryptic names like `sd()`.

### 4. Procedural instead of declarative

Flag:
- No intent CTE. The first CTE should say what is being done, as values and arrays, so a reader
  who knows neither tera nor self-dispatch can tell.
- CTE soup: steps instead of named relations of 4–8 lines.
- Transactions and row-by-row inserts or updates where one set-based statement would do.
- A `CREATE TABLE` inside a dispatched statement. Dispatched statements read, or insert into
  a table that already exists.
- Polling loops, queues or recursive walks where a set read, or a filtered listing dispatched per
  level, would do.
- A query that can't be lost and rewritten from its relations, or that changes state when re-run.

### 5. Missing shared relations, or too many bespoke ones

Ask what relation this work should have left behind for everyone: a view over the raw files, a
verb relation, a host-state view. Flag:
- Raw data not kept, or no unmaterialized view over it.
- Bespoke tables per question (`north_dakota_revenue`), six to ten temp tables, a view that
  restates a table at another grain.
- A new table or macro created without a proposal to the owner.

The shape to look for: a relation that carries just the keys (urls, paths, ids) and feeds the
next self-dispatch, which fills a different table.

The reference for doing this right is inframe PR #1576: everything set-based and declarative, a
reader chosen per file type by data.

### 6. SQL built from strings

Flag quote-building from character codes, printf-style plumbing, nested quotes, doubled quotes
and escapes. Statements come from word arrays and `quote_literal`, or a generic tera template
that only substitutes. Templates with loops, conditionals or business logic are findings: logic
lives in SQL. Tera constructs a statement and nothing else. A new template file is a finding
unless the statement's shape is new: call an existing one with `template_path :=`.

### 7. Defined schemas

Flag any schema the code writes out: `columns := {...}`, `from_json` structure strings, typed
NULL columns, `CREATE TABLE` column lists, named-key lists that break when a key goes missing.
DuckDB infers it (`read_json`, `read_csv`, `json_tree`). If it can't, the data stays raw
(`read_lines`, text, JSON) and gets parsed at use. When the change touches a hand-typed schema
someone else left, the fix removes it too.

### 8. Banned habits

The house list in `~/.claude/CLAUDE.md` and memory: values clauses, star counts, limit-one,
recursive CTEs, regex on structured or backend data, positional splitting of structure, OR
chains (use `IN`, `IS DISTINCT FROM` or a set of terms), aggregate filter clauses, scalar
subqueries in a select list, forced materialization, left-joined lateral unnests.

### 9. Bloat

Compare length to purpose. A server setup over ~90 lines, an extension catalog over ~60, a
pipeline that needs more than a screen: find what can be deleted. Fix by simplifying, not by
adding a guard.

### 10. Parquet

Parquet is temporary: a carry across a light switch, or a shared output directory written with
`COPY … (FORMAT parquet, OVERWRITE_OR_IGNORE)`. Flag Parquet used as a cache to hide a heavy
view (fix the view), and inserts where a COPY would do.

## What good looks like

```sql
WITH intent AS (                          -- what is being done, as data
    SELECT parent AS path, ['git', '-C', parent, 'log', '--oneline', '-5'] AS cmd
    FROM fs.folders WHERE name = '.git'
), rendered AS (                          -- generic template, substitution only
    SELECT path, tera_render('reader-shellfs.tera', intent::JSON, autoescape := false,
                             template_path := '<templates>/*.tera') AS sql
    FROM intent
), dispatched AS (                        -- visible self-dispatch
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT r.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(r);
```

A live view straight over a CLI reader is fine and readable:
`CREATE OR REPLACE VIEW gh_open_prs AS SELECT 'asubbarao' AS account, * FROM read_json($cmd$gh search prs … --json …|$cmd$)`.

## How to run it

1. Read SQL-MANIFESTO.md, then the diff (`duck_tails`, or `gh pr diff` read through shellfs).
2. Go through checks 1–10 in order. Run what can be run on dev: `EXPLAIN`, row counts as
   `len(array_agg(…))`, timing. A claim about speed needs a measurement.
3. For each finding, give the rewrite in the target shape, not just the complaint.
4. Verdict: findings by check, the one change that would most improve the work, and the shared
   relation it should have created.
