# duckdb-llm-waves

**LLM map-reduce in pure SQL.** Point it at a directory: DuckDB crawls the
tree, reads every admitted file into a corpus, assembles worker prompts
in-database, launches N parallel headless LLM workers *from a query*, and
lands their JSON back in an append-only catalog — validated, joined, and
honest about anything that didn't make it.

There is no queue, no broker, no workflow engine, no daemon — and no shell
orchestration and no shell files: a launcher is the `duckdb` command line, and every piece
of logic (prompt assembly, worker launch, the wait barrier, ingest,
reporting) is a query. The orchestrator's entire state is **derived, never
mutated**:

| concern | usual answer | here |
|---|---|---|
| what's left to do | status column + UPDATE | `pending` = corpus **ANTI JOIN** catalog |
| who works on what | claim rows, locks, leases | `hash(signature) % n` — disjoint by construction |
| where results go | task queue → DB writer | `COPY … PARTITION_BY (batch_sig), APPEND` — one sink, any number of simultaneous writers |
| did the worker lie | trust, or re-scrape | workers **echo each document's wire key**; a mangled key is a visible join miss, never a silent loss |
| crashed worker | requeue logic, dead-letter | costs nothing — its shard simply stays pending; re-run the wave |
| re-processing after edits | invalidation bookkeeping | `signature = md5(path\|mtime\|size\|section)` — edited files fall back into pending by themselves |
| document versions | audit tables, triggers | old catalog rows persist; the `history` view is version history for free |
| files too big for a worker | special-case chunker | **sections**: a whale is just more corpus rows, same shards, same waves |
| what went over the wire | experiment tracker, prompt-version columns | `log/` — every request and response **verbatim**, appended before the scratch recycles; identity = `md5` of the bytes |
| this run's parameters | session state, env vars, config | a **runs row** — argv becomes one INSERT; every stage reads the latest committed row |

## Quickstart

Needs: a stock DuckDB CLI (developed on 1.5.3) and any single-shot LLM CLI
that takes a prompt and emits `{"files":[…]}`-shaped JSON (`grok` by
default — the invocation sits in plain sight in `sql/wave.sql`).

```bash
duckdb waves.duckdb -f sql/init.sql                                                       # provision (idempotent)
duckdb waves.duckdb -c "INSERT INTO crawls SELECT '/abs/repo', now()::TIMESTAMP" -f sql/crawl.sql -f sql/corpus.sql
duckdb waves.duckdb -c "INSERT INTO runs BY NAME SELECT uuid()::VARCHAR run_id, 'summarize' task, 6 n_workers, 8 batch_size, 40 min_chars, 25000 max_chars, now()::TIMESTAMP started_at" -f sql/wave.sql -f sql/report.sql
```

No shell files. A launcher is the `duckdb` command line: argv is one `INSERT`, the stages
run by path, `-f` keeps `~/.duckdbrc`.

`sql/init.sql` provisions (community exts, tasks, ledgers; idempotent, re-run any time).
Each stage is a `.sql` run by path; the per-folder `ls` and per-list `read_blob` that need
a literal are self-dispatched to a quackapi route the same process serves. The report is a
plain query — `duckdb waves.duckdb -markdown -f sql/report.sql`.

Every stage prints a validation tail with its expectations stated
(`join_misses MUST be 0`, `corpus_files MUST equal map_files`). If a number
is wrong you find out at the stage that broke, not three stages later.

## How it works

**Parameters are rows, not state.** a wave is one
`INSERT INTO runs`; every stage opens by unnesting the latest committed runs
row (ordered `array_agg`, first element — no `LIMIT 1`, no `max`) and joins
against it. No `SET VARIABLE`, no env plumbing — argv touches SQL in exactly
one INSERT, and the run's parameters are queryable forever because they are
data.

**Where data must become a table function's input, the query dispatches
itself.** `ls`'s directory and `read_text`'s path list bind at parse time —
they take a literal, not a column — so you cannot `LATERAL ls(frontier.path)`.
The self-dispatch crosses that wall: a CTE **builds** the `ls`/`read`
statement as a string per row, the next column POSTs it (`http_post_form` — a
scalar, so it *does* take a column) to a loopback SQL executor that parses it
fresh, and the JSON result comes back to `CROSS JOIN UNNEST`. Generated SQL in
a column, crossed by an HTTP self-post. It runs **through the quack server**:
quack holds the state and the extensions; the executor is a dumb loopback the
one `dispatch` macro names (fold it into quack and only that URL changes).

**The crawl is crawling-incremental-ls** (`sql/crawl.sql`): levels as
partitions of `node_map`. Drop the junk *by name* — `node_modules`, `.venv`,
dotfolders — *before* descending, `ls` only the survivors, one level at a
time. Each level is one `INSERT` whose frontier reads the prior committed
partition, self-dispatches an `ls` per directory, and keeps only what
`keep_node` admits. No `WITH RECURSIVE` (the unrolled level chain *is* the
recursion), no `lsr` (it walks vendor trees before any `WHERE` can filter
them), no `MATERIALIZED`, no `UPDATE`.

**The reader is total** (`sql/corpus.sql`): one dispatch per
`(folder, ext, chunk)` carrying an **explicit** `read_text(['a','b',…])` list
— never a glob (a zero-match glob is an *error*), and the list matches the
*map*, not the *filesystem*, so policy-excluded junk can't re-enter. Misses
cascade to `read_blob` + `BLOB::VARCHAR`, a cast that cannot throw (invalid
bytes come back `\x`-escaped) — so there is no `read_errors` table, because
after the cascade no unread files exist. The proof is result-level: admitted
files **ANTI JOIN** corpus `= 0`.

**Launching LLMs is also a query** (`sql/wave.sql`). A `COPY` writes
`launch.sh` from the prompt files on disk — reset `out/`, background every
worker, `wait` — and scanning one row from the constant shellfs pipe
`'sh launch.sh |'` *is* the launch, the parallelism, and the barrier: the
row arrives when the last worker exits, and its value is the worker-output
count.

**Whales become sections, not special cases.** A file bigger than one
worker's context is exploded into 24k-char sections at corpus build — each
its own row, its own signature, its own `path#sN` wire key. Sections flow
through the same shards, waves, and honesty joins as everything else.

**Tasks are rows, not code** (`sql/init.sql`). A task is one row in
`tasks`: its instructions and one worked example. The output contract is
fixed for every task — one entry per document, `{path, out: [strings]}` —
so ingest is task-agnostic and adding a task is an `INSERT`. Ships with
`summarize`, `distill`, and `classify`.

**Prompts use the boring, load-bearing structure** (`sql/wave.sql`,
in the open): a role preamble that names the parser ("your output is parsed
by a SQL join, not read by a human"), the task's instructions, hard rules
(verbatim keys, `out: []` allowed, no invention, exact entry count), one
worked example entry, the delimited documents with an explicit count — and
the contract **restated after the documents**, because long-context models
weight the ends of the input. Pending is written as the ANTI JOIN it is,
sharding is a `hash(signature) % n_workers`, and one
`COPY … PARTITION_BY (k)` writes every worker's prompt for any worker
count.

**Ingest is a join, not a parse-and-hope** (`sql/wave.sql`). Worker
JSON (bare or grok's `.structuredOutput` envelope — both parse) joins back
to the corpus by the echoed wire key. Landed rows carry `path`, `mtime`,
and `section` alongside the signature, so the catalog is self-describing:
`history` shows every version of every document ever landed, across any
number of corpus rebuilds. `runs` records every wave, append-only.

**The wire is logged, verbatim.** `prompts/` and `out/` are disposable CLI
transport — but before the launch recycles them, the exact bytes are appended
to one `log/` sink, `PARTITION_BY (kind, wave_sig)`: every request as
assembled, every response as received, keyed by the wave's identity
(`wave_sig` = `runs.run_id`) and `md5(body)`. There is no prompt-version
column and no experiment schema because none is needed — when the verbatim
request is logged, "which version of the prompt produced this" and "has this
exact prompt been sent before" are queries, not metadata someone maintained:

```sql
SELECT * FROM read_parquet('log/*/*/*.parquet', hive_partitioning := true);
```

## The one number that matters

`join_misses MUST be 0`, printed by every ingest. Structured-output schemas
pin the *shape* of what a model returns; the echoed-key join pins the
*referent*. A worker that mangles one wire key produces a named, counted
join miss — the failure mode "plausible output attached to the wrong input"
is converted from silent corruption into a query result.

## Layout

```
sql/init.sql       extensions + policy, task registry, ledgers, catalog seed, views
sql/crawl.sql      crawling-incremental-ls: the self-dispatch tree walk -> node_map
sql/corpus.sql     the total read: read_text -> read_blob cascade -> sectioned, signed corpus
sql/wave.sql       prompt assembly + parallel launch + ingest (the LLM map-reduce)
sql/report.sql     coverage + the latest wave's results
figures/           SVG figures, generated by DuckDB itself
waves.duckdb       state (gitignored)
catalog/           append-only result partitions (gitignored)
log/               verbatim wire log: every request + response (gitignored)
```

Five SQL stages carry the logic; the launchers are thin and each is a whole
action — `crawl.sh` runs three stages, `wave.sql` maps and `report.sql`
answers, both from one `wave.sh`. A stage you want on its own is just
`duckdb waves.duckdb -f sql/<stage>.sql`.

## Extending

- **New task**: `INSERT INTO tasks VALUES ('extract-todos', '…instructions…',
  '…example entry…')`, then a runs row with task `extract-todos` and `-f sql/wave.sql`.
- **Corpus policy**: edit `policy_skip_dirs` / `policy_exts` — the crawl
  reads them; nothing else changes.
- **Other worker CLIs**: the invocation is one visible line in
  `sql/wave.sql`; ingest already parses bare `{files:[…]}` output.
