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

Every review, passing or not, also hunts for the shorter version: fewer lines, more declarative,
set-based and elegant. Look for repeated expressions a list or a relation can hold, steps a single
set-based statement can replace, columns derived once instead of in every reader, and ladders,
chains or branches that collapse into data. Give each rewrite with its line count before and after.
A change that works but could be a third shorter is a finding.

### 1. Self-dispatch, or the lack of it (the main failure)

Self-dispatch is `array_agg` of posts to self, then `CROSS JOIN UNNEST` of the receipts.
It removes binder limits, keeps a pipeline to one query, and runs rows together.
Across a month of transcripts this was the owner's most repeated complaint, and the root of most
"why is this so slow" and "why did it crash" moments.

Flag:
- A column passed into `read_csv` or `read_text`, or a comment explaining a binder error away
  ("only accepts a literal"). A binder error means: self-dispatch.
- A lateral join on a table function or a `read_*_lateral` that the self-dispatch form would beat.
  LATERAL is allowed, but self-dispatch usually wins: a LATERAL that stays needs a measurement
  (latency or rows moved, both forms on the same input) showing it is the faster one. With no
  measurement, it is a finding.
- Self-dispatch mixed with LATERAL, or receipts matched to their inputs by array position. Each
  dispatched statement selects its own keys.
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
and escapes. Statements come from word arrays and `quote_literal`, a generic tera template that
only substitutes, or one `concat` of at most two holes (RULES.md 12). Templates with loops, conditionals or business logic are findings: logic
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

The owner's own examples (2026-10-17); he wrote the post out as `quackapi_post(...)`, written here as
`selfdispatch(sql)`, the same call since PR #50. The first CTE declares everything; tera only substitutes; the
reader is `SELECT *` and brings its own columns; the result is `receipt.*`:

```sql
WITH c AS (
    SELECT unnest(['/tmp', '/Users/aloksubbarao/inframe']) AS path
), rendered AS (
    SELECT tera_render(
        $tera$
        SELECT * FROM read_csv(
            $cmd$find "{{ path }}" -maxdepth 1 -type d |$cmd$,
            header := false
        )
        $tera$,
        c::JSON,
        autoescape := false
    ) AS sql
    FROM c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts
    FROM rendered
)
SELECT receipt.*
FROM dispatched
CROSS JOIN UNNEST(receipts) AS t(receipt);
```

`selfdispatch(sql)` is exactly `quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)`: the
post always goes to dev itself, and whatever varies by row goes inside the statement. A query that hand-writes the
post, takes a URL per row, or builds it with `url_build` is a finding.

```sql
-- a template file
SELECT tera_render('select.tera', c::JSON, autoescape := false, template_path := './templates/*.tera') AS sql
FROM information_schema.columns AS c;

-- an inline template; the row is the context
SELECT tera_render('SELECT {{ column_name }} FROM {{ table_schema }}.{{ table_name }}', c::JSON, autoescape := false)
FROM information_schema.columns AS c;
```

## Bad, then good: real failures

Each of these was written by an agent and rejected. Flag the left side on sight.

**Bash loop over hardcoded ids, JSON built with sed** (check 1, 2):
```sql
-- BAD
SELECT TRY_CAST(content AS JSON) FROM read_lines($cmd$for f in a35d1dd0-… 1f833096-… 8bd35984-…; do
  tail -n 300 ~/.claude/projects/-Users-aloksubbarao-inframe/$f.jsonl | sed "s/^/{\"_s\":\"$f\",\"_l\":/; s/\$/}/"; done |$cmd$)
```
```sql
-- GOOD: the ids are rows; one statement per row; receipts unnested
WITH c AS (
    SELECT name, getenv('HOME') AS home, replace(cwd, '/', '-') AS project, sessionId AS session_id
    FROM terminal_sessions WHERE sessionId IS NOT NULL
), rendered AS (
    SELECT tera_render($tera$
        SELECT * FROM read_json($cmd$tail -n 200 "{{ home }}/.claude/projects/{{ project }}/{{ session_id }}.jsonl" |$cmd$,
                                format := 'newline_delimited')
    $tera$, c::JSON, autoescape := false) AS sql
    FROM c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
```

**printf building a path, the reader's schema declared, arrows digging into the result** (checks 6, 7):
```sql
-- BAD
SELECT printf('%s/.claude/projects/%s/%s.jsonl', getenv('HOME'), replace(cwd, '/', '-'), sessionId) AS path …
… read_json(…, columns := {'type': 'VARCHAR', 'timestamp': 'VARCHAR', 'message': 'JSON'}) …
… read_json(…, maximum_depth := 1) WHERE type ->> '$' IN ('user', 'assistant') …
… CASE json_type(message -> 'content') WHEN 'VARCHAR' THEN message ->> 'content' ELSE message ->> '$.content[0].text' END
```
GOOD is the query above: values in the first CTE, the template substitutes them, `SELECT *`, `receipt.*`.

**Parquet snapshots in the hot path of a one-query job** (checks 9, 10):
```sql
-- BAD: a reaper that COPYs every process to Parquet every 5 minutes before it kills anything
COPY (SELECT *, strftime(observed_at, '%Y-%m-%d') AS day FROM host_processes) TO '~/.duck/logs/processes' (…);
```
```sql
-- GOOD: the kill is one query over the live view; nothing is stored
WITH targets AS (SELECT list(DISTINCT '-' || pgid) AS groups FROM host_processes WHERE reap) …
```

**Rejected on 2026-10-17, each in one line** (the left side is a finding on sight):
- `QUALIFY row_number() OVER (…) <= 3` to pick rows → `arg_max` / `max_by`, or a join on keys.
- A whole command built in one `printf($s$…%s…$s$, id)` string → declare the parts as columns, render with Tera.
- `json_object('schema', '[{"session":"VARCHAR","line_number":"BIGINT"}]')` or any typed key list → the reader infers.
- `to_base64(encode(event::VARCHAR))` to carry content → the content is a column of the dispatched statement.
- `COPY (…) TO 'x.parquet'` then `read_parquet('x.parquet')` in the next stage → unnest the receipts; the skill is a
  query someone can wrap in a `COPY` themselves.
- "read_ast needs a literal list, so I passed the nine paths as literals" → that is what self-dispatch is for.
- Three `.sql` files of hardcoded AppleScript strings for open / read / close → one view of verb rows and one query
  over it with Tera.
- A wait row between two steps → the next step's statements are built from the previous step's receipts.
- Code offered without having been run → run it and show the rows.

A live view straight over a CLI reader is fine and readable:
`CREATE OR REPLACE VIEW gh_open_prs AS SELECT 'asubbarao' AS account, * FROM read_json($cmd$gh search prs … --json …|$cmd$)`.

## How to run it

Every PR on asubbarao/duckstack goes through the review queue ([queue.sql](queue.sql), launchd every minute), and
main accepts only PRs with both of its statuses green:
- `duckstack/rules`: [gate.sql](gate.sql) runs the hook's own checks (`hooks/hook_checks.sql`) on every changed
  `.sql` file and ```sql block, exactly as on an agent's tool call. A new antipattern the owner names is one more
  row in `hook_checks.sql` (then `hooks/render_hits.sql`); it then blocks tool calls and PRs alike.
- `duckstack/review`: this skill, run by Opus 5.5 headless on the lines the PR adds, with RULES.md and the manifesto.
Findings come back as a PR comment; push a fix and the new head is checked again. Auto-merge does the rest.

By hand:
0. Run [references/audit.sql](references/audit.sql) on dev: one query, every rule hit in skills/ and server/ as
   file:line:rule. New antipattern named by the owner = one more row in its `rules` CTE.
1. Read SQL-MANIFESTO.md, then the diff (`duck_tails`, or `gh pr diff` read through shellfs).
2. Go through checks 1–10 in order. Run what can be run on dev: `EXPLAIN`, row counts as
   `len(array_agg(…))`, timing. A claim about speed needs a measurement.
3. For each finding, give the rewrite in the target shape, not just the complaint.
4. Verdict: findings by check, the one change that would most improve the work, and the shared
   relation it should have created.
