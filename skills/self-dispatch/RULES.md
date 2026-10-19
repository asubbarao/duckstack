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
   inside one array use `WITH ORDINALITY` / `array_sort` only when order matters, otherwise it is async (09-24, 10-08).
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
    (`c::JSON`): `templates/` here holds shell, pipeline, sql, network and loop (10-16, 10-17). "if tera dont
    help reduce complexity, we will toss" (10-08). Someone without the `.tera` files must find the SQL easy
    to rewrite without Tera (10-16).

## Tools

18. **Every host command through shellfs readers** with their `:=` options: `read_csv` / `read_json` /
    `read_lines('cmd |')` for curl, gh, git, osascript, aws, codex (09-28, 10-08, 10-11 "curl is not
    banned through shellfs"). Never `column0 VARCHAR`: use the reader's options. `read_text` is batch,
    `read_lines` streams. At most a simple `jq` in the pipe; no `sed`/`tr`/`awk` — do it in SQL (09-24, 09-29).
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
