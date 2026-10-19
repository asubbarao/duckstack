# Alok's rules for SQL and self-dispatch

Curated 2026-10-17 from every one of Alok's messages about SQL, self-dispatch, Tera and DuckDB tooling
(514 messages, Claude and Codex, 2026-09-18 → 2026-10-17, read from dev's agent stream). Each rule is
what he said, with the date. These override any skill, memory or habit that disagrees. Read this before
writing SQL on this machine.

## Self-dispatch

1. **Self-dispatch is unnesting an array of self-posts.** Build the statements in a CTE; the next CTE is
   `array_agg(selfdispatch(sql)) AS arr`; then `FROM prior CROSS JOIN UNNEST(arr)`. Always, even for one
   statement. "you never send a fucking post by itself … it's in an array that you un nested it's two CTE
   that's why it was called the molecule" (09-22). "the arr is an arrayagg of the selfdispatchmacro(sql
   statement)" (10-17). No `flatten`, no `LEFT JOIN LATERAL`, no lone `http_post`.
2. **Each pair of CTEs is one orchestration step.** The next step's statements are built from the previous
   step's receipts: "a single selfdispatch, flicks on it, then the SUBSEQUENT SELF DISPATCH clicks on the
   next link … each duo of selfdispatch is an orchestration" (10-17). Order comes from that dependency;
   inside one array use `array_agg(… ORDER BY …)` / `array_sort` only when order matters; `WITH ORDINALITY` only
   numbers the elements; otherwise it is async (09-24, 10-08, 10-14).
3. **Self-dispatch is the escape hatch for every binder error.** "self-disaptch works in all cases. it BYPASSES
   all binder errors and allows concatenating col params into table functions" (09-24). Never claim a reader
   "needs a literal", never `SET VARIABLE`/`getvariable` hand-offs, never `query()`/`query_table` (09-20, 10-08, 10-13).
4. **Nothing should error.** "if it starts with hostfs and find, the first cte would return a null set. there
   would then be no error" (10-16). A failed reader comes back as a receipt; fall back with
   `coalesce(read_csv…, read_blob…)` (09-23, 09-30).
5. **Results come back as columns.** "whatever you construct in the self dispatch you unnest the arr and it
   comes back as a column … if agents are manually parsing out field names like that I am going to vomit" (09-22).
   Until quackapi returns typed replies, a receipt body field may be read with one `->>` (no chained arrows),
   once, in the CTE right after the unnest, which names it as a column for every later reader; no ladders, no
   `from_json` structures (10-18).
6. **No scripts around it.** No `.sh`/`.py` files, no COPY-a-script-then-run-it, no base64, no nohup
   launchers, no polling loops: the command is a column and gets dispatched (09-20, 10-09, 10-12, 10-14, 10-16).
   "you're a fucking moron if you think an sh file is needed" (10-12).

## Declarative, readable SQL

7. **Declare everything up front in the first CTE**: paths, commands (as arrays), reader options, prune
   lists. "everything declared upfront in the first CTE" (10-17). "there would be a cte that derives these
   as arr or struct, then the json object" (10-16).
8. **Code as data.** Grammar, selectors, verbs, mappings are rows in a view, joined by key; the query never
   hand-writes them (09-18 selectors, 09-27 "chrome_windows, chrome_tabs unmaterialized views", 10-17).
9. **Short.** "the way to tell that schema is elegant is you can't actually shrink" (09-30). "80 lines, one
   single query" not 868 (09-23). CTEs of 4–8 lines; put `UNNEST` on its own line if it reads better (09-29, 10-08).
10. **Lossless.** Keep columns (`SELECT * EXCLUDE`, columns are free); derive a flag with `CASE` and filter
    in the next CTE; never silently drop rows or columns; aggregate with `array_agg`, not min/max/count;
    no manual pivots (use `PIVOT`) (09-22, 09-24, 10-01).
11. **Views first, tables later.** Raw files, shellfs and hostfs output are unmaterialized views; query
    until the result is right, then save the `.sql`; no castles of temp tables (1–2 staging tables are
    fine); no per-question tables like `north_dakota_revenue` (09-29, 10-14, 10-15). `CREATE OR REPLACE
    TABLE t AS SELECT … FROM t`, no `BEGIN`/`COMMIT`, no `INSERT` when CTAS works (09-23).
12. **Readable strings.** Arrays of words, a canonical template with holes (rule 17: shell, pipeline, sql,
    network, loop), or one plain `concat` of at most two holes (10-18); no `||` chains, no `chr(39)`/`chr(10)`
    gymnastics, no nested quotes or escape hell (09-22, 10-12). `quote_literal(col)` is fine; `translate()` for
    character swaps (09-23, 10-16). No `printf` / `format`: on 10-17 a printf-built command and a printf in a
    dispatch were both rejected; declare the parts as columns and render with Tera.
13. **Banned:** `VALUES`, `COUNT(*)`, `LIMIT 1`, `OR` chains (use `IN`, `IS [NOT] DISTINCT FROM`, null
    checks), `WITH RECURSIVE`, scalar subqueries in SELECT lists, `any_value`, cross joins of singleton CTEs
    (`JOIN ON true`, comma joins), `json_extract` ladders and selector-taking extractors in committed code (except the single `->>` per receipt
    body field allowed by rule 5),
    regex on backend data, `generate_subscripts`, positional `split_part` surgery (09-22, 09-23, 10-10).
14. **Descriptive names** for CTEs and aliases; "sd is not descriptive at all" (09-22).
15. Spell out the `array_agg` column and name it; turn it into text with `tera_render` (a template that substitutes
    the array) or `string_agg` over rows, never `array_to_string`, which the hook blocks (09-22, 10-17).

## Tera

16. **Tera is a constructor, not the program.** "tera is just to make code readable. you have to create the
    code as data first … tera is a helper" (10-17). Logic stays in SQL; no `{% if %}` logic (10-15). A
    `{% for %}` only for output that is genuinely loop-shaped (an osascript or bash loop) when that is
    simpler (09-28, 10-15).
17. **A few canonical templates by shape**, called by name with `template_path :=` and the row as context
    (`c::JSON`): `templates/` here holds `sql.tera` (a SQL statement), `shell.tera` (shellfs readers),
    `bash_loop_fallback_method.tera` (a shell loop, the fallback) and `network.tera` (a request to another host,
    including an array of statements sent to another DuckDB's `:9495`) (10-16, 10-17, 10-18). Git data comes from the
    duck_tails views already on dev (`git_changes`, `branch_diff`, ...), joined; no template needed (10-18). "if tera dont
    help reduce complexity, we will toss" (10-08). Someone without the `.tera` files must find the SQL easy
    to rewrite without Tera (10-16).

## Tools

18. **Every host command through shellfs readers** with their `:=` options: `read_csv` / `read_json` /
    `read_lines('cmd |')` for curl, gh, git, osascript, aws, codex (09-28, 10-08, 10-11 "curl is not
    banned through shellfs"). Never `column0 VARCHAR`: use the reader's options. `read_text` is batch,
    `read_lines` streams. No `sed`, `tr` or `awk` in the pipe, and no `jq` beyond shell.tera's fixed
    `jq -c '.[]'` array split; parse in SQL with json_schema or the reader's options (09-24, 09-29, 10-14).
19. **Use the extensions built for the job:** hostfs for the filesystem, duck_tails for git, duck_hunt for
    test/CI logs, sitting_duck and parser_tools for code, webbed for HTML, agent_data / `agent.stream` for
    transcripts, urlpattern / netquack for URLs, scalarfs for content-as-file. Never grep/find/cat (10-07, 10-08, 10-14).
20. **Crawls:** list a level, prune by name in a CTE, self-dispatch the survivors, repeat. "the lsr() is
    not the final but starting point" (10-09); "with allfolders as (find -d ~) … SELFDISPATCH lsr()" (10-16).
21. **Macros only with Alok's approval**, and only for true primitives (selfdispatch, quote_literal, a
    shell runner). Prefer views (09-22, 09-24, 10-16).
22. **Browser:** locate tabs from `chrome_tabs`/`browser_tabs` and act on them; never open, close, navigate or
    focus Alok's tabs. A click is a request: prefer an HTTP request (cookie jar, `quackapi_post`) over driving
    the UI (10-17).

## Process

23. **Query first.** Issue SELECTs, shape with `LIMIT 4`/`7`, save the file once it is good (09-29).
24. **Never declare it impossible.** "needs a literal", "extension missing", "permission", "dev is down"
    are not findings: fix it or flip the switch (10-08, 10-09).
25. **Write down what was verified**, delete wrong advice, in skills and memory, for Claude and Codex both (09-24, 09-28).
26. **Everything is tested before it is offered.** "whywouldnt everything be testd" (10-17); "I have no use for
    some AI slop that the AI didn't even test" (10-17). Run it, show the rows.
27. **Code reaches main through a PR that passed the review queue** (skills/duckstack-review/queue.sql): the
    hook's checks on every changed file, then an Opus review against this file. Nobody pushes main (10-17).

## Added 2026-10-18 from every session

Mined from all 5,361 of Alok's prompts that mention SQL, dispatch, Tera or DuckDB tools (Claude and Codex,
2026-09-14 → 10-18, read with the agent-stream skill's prompts query). Only rules not already above.
Where two of his messages disagree, the newer wins. "(hook)" means `hooks/hook_checks.sql` now enforces it.

**Dispatch shape.** The shape in rule 1 is a block (hook `sql_dispatch_shape`). Each row's statement is a concat
or a template render, the rows are sent as `array_agg(selfdispatch(sql))` grouped by the row's columns, then
`CROSS JOIN UNNEST` and `receipt.*`. The reference is `SKILL.md`. Because every dispatch takes that shape, the
receipt problems below have one place to be checked.

28. **Receipts are columns.** Read `receipt.status`, `receipt.error` and `receipt.body` as columns. The body comes
    back from /sql as JSON text, so one `->>` per field you use is accepted until quackapi returns typed replies.
    Ladders (`->'a'->'b'->>'c'`) and hand-typed `from_json` structures are not (10-09, 10-13, 10-14; tested 10-18:
    reading a body back through `read_json('data+varchar:…')` returns JSON text again).
29. **Check every stage's receipts.** The next stage filters on `receipt.status` and keeps failed receipts as
    rows behind a flag. A timeout, an error status or an empty or unparsed body counts as a failure, not as
    an empty result (10-14, 10-16). Judge by `receipt.status`: a failed statement comes back as a 500 with the
    error in the body and `receipt.error` NULL (verified 2026-10-18).
30. **One array, one `CROSS JOIN UNNEST(receipts)` per step**, never `unnest(receipts)` in a SELECT list. A receipt stays on its
    source row, so nothing joins back afterwards (10-12, 10-13).
31. **Source rows are real rows** (catalog, hostfs, a table), never `range()` / `generate_series` (hook, 10-12).
    No sleep or wait rows (hook, 10-17).
32. **Post through the macro.** Use `selfdispatch(sql)`, never `quackapi_post('…:9495/sql', …)` by hand (hook).
    Never curl /sql from a reader (hook, 10-16). Never `quack_query` back to dev (10-09, 10-14). Never add a
    route that /sql already covers; fix /sql instead (10-09, 10-12).
33. **Inside generated statements:** create views, not tables (10-13, 10-14). A constant statement runs as is,
    not wrapped in a dispatch. Never paste a `$$` body inline; render it from a template (10-09, 10-12).
    Pass the row as `c::JSON`, not `row_to_json` (hook, 10-15). Never pass a subquery as a table-function
    argument (10-13).
34a. **The row keeps its columns.** `SELECT pr_number, array_agg(selfdispatch(sql)) AS receipts … GROUP BY ALL`,
    then `CROSS JOIN UNNEST(receipts)`: each receipt sits beside its row's `pr_number`. The statement itself is just a
    concat (`concat('SELECT * FROM read_csv(', quote_literal(path), ')')`); a template is for when the holes get many.
    Never two parallel arrays matched by position (`prs` plus `receipts[n]`) (hook, 10-18).
34b. **Nested `tera_render` is allowed when it helps**, for example a statement that itself dispatches further: render the
    per-row statements, `array_agg` them, and send that whole array to another host's `:9495`, which self-dispatches
    it. Don't nest when one render plus a CTE does the same job (10-18).
34c. **Command words are split by role in the first CTE**: the program (`[gh, 'pr', 'list']`), its arguments and
    its flags as separate arrays, then put together with same-query aliases (`list_concat(gh_pr_list, repo_args,
    list_flags)`). A parallel comments array is optional (10-18).
34. **Push the filter into each generated statement**, so a receipt carries only what is needed (10-08, 10-09).

**Readers and shell.**

35. Use plain `read_csv` / `read_json`, not the `_auto` variants (hook, 09-16, 09-29).
36. `read_text` over a pipe needs a stated reason (hook warns, 10-10, 10-13).
37. A shellfs pipe never contains:
    - `tail` / `head` (hook, 09-29);
    - a `timeout` wrapper, since the tool's own option bounds it (hook, 09-15);
    - an inline `duckdb -c` program; make the read a view (hook, 09-25). A checked-in `.sql` run with
      `duckdb -f` as its own process is fine;
    - `|| true` / `; true`, since the shell template takes the accepted exit codes (hook warns, 10-16).
38. Hard-code no `/Users/…` path. Use scalarfs path variables, `getenv('HOME')`, or a column declared once
    (hook warns, 09-25, 10-15).
39. Git status and diff come from a view: the hostfs tree joined to duck_tails `git_tree` hashes. Never shell
    out to `git diff` / `git status` (10-13).

**SQL forms.**

40. No `replace(replace(…))`: use `translate()` or a template (hook, 09-30). No `list_transform(range(…))`
    index loops (hook, 10-08). Never pick by position (`split[1]`, neighbour joins on `i + 1`) (10-09, 10-13).
41. `QUALIFY` and `first_value` / `last_value` are suspect. Use `arg_max` / `max_by` or a key join (hook warns,
    10-08, 10-15). Never `MERGE INTO`; use CTAS or `INSERT OR REPLACE … BY NAME` (10-09).
42. Appended tables have a key and take `INSERT OR IGNORE` / `OR REPLACE … BY NAME` (10-08).
43. Profile with `SUMMARIZE` / `DESCRIBE`, never a list of per-column aggregates (09-29, 10-08). Keep
    `array_agg(ts)` and take `list_min` / `list_max` later (10-01, 10-08).
44. A `CASE` classification returns a descriptive label, not `true` / `false` (09-30). Label union branches
    with a projected scalar, not `* REPLACE (literal AS col)` (10-09).
45. Filter a view with `WHERE`, never through a macro that takes a path (10-13). Derive input lists from
    relations, never as typed literal lists (10-08).
46. Refresh incrementally from a watermark: `max(ts)` or the hostfs mtime, plus an anti-join. Fetches skip
    what is already stored, so a rerun only shrinks in scope (10-08, 10-14).
47. Never COPY a result out and read it back. Put `CREATE OR REPLACE TABLE … AS` on the SELECT (09-29).
48. In exploratory queries show `len(content)` with `[left(content,100), right(content,100)]`, never the full
    text (10-02, 10-04).
49. Credentials are `CREATE SECRET` statements in setup.sql, read from env vars (09-30). Postgres objects
    are created with `postgres_execute` in Postgres SQL, not with ATTACH plus DuckDB DDL (09-30).
