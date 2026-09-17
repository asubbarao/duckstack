-- ============================================================================
-- init.sql — waves.duckdb: community extensions + policy, task registry,
-- ledgers, derived views. Idempotent, plain DDL — the STATIC substrate.
-- bin/crawl.sh runs this FIRST (provisioning), then the walk (sql/crawl.sql)
-- and read (sql/corpus.sql) add the self-dispatch macros + node_map + corpus
-- onto this same db THROUGH the quack server. Re-run any time: editing a
-- policy table and re-crawling reloads it (there is no separate init step).
-- ============================================================================
-- The design in one line: ORCHESTRATOR STATE IS DERIVED, NEVER MUTATED.
--
--   pending  = corpus ANTI JOIN catalog         (no status column, no UPDATE)
--   shards   = hash(signature) % n              (disjoint by construction,
--                                                nothing to claim, no locks)
--   results  = append-only parquet partitions   (concurrent workers, ONE sink)
--   honesty  = workers echo each document's wire key; ingest joins it back to
--              the corpus, so a mangled key is a VISIBLE join miss in the
--              validation tail — never a silent loss.
--   params   = a row. bin/wave.sh INSERTs one runs row; every stage reads the
--              latest committed row. argv touches SQL in exactly one INSERT.
--
-- A dead worker costs nothing: its shard simply stays pending. Re-running a
-- wave picks it up. There is no queue, no broker, no state machine to repair.
--
-- The signature does three jobs at once:
--   identity     md5(path|mtime|size|section) — deterministic, no sequences
--   concurrency  hash-sharding + batch_sig partitions let any number of
--                agents write the ONE sink simultaneously
--   versioning   an edited file gets a NEW signature: it re-enters pending
--                by itself, and its old catalog rows REMAIN — the catalog
--                accretes document versions (see the history view)
--
-- Files larger than one worker's context are SECTIONS in the corpus: same
-- signatures, same shards, same waves — a whale is just more rows.
--
-- Where data must become a table function's input — the crawl root into ls,
-- the path list into read_text — it CANNOT cross as a bind-time value: those
-- functions take a literal, not a column. The self-dispatch crosses that wall
-- (sql/crawl.sql): the value is BUILT into an ls/read statement string per row
-- and POSTed to a loopback SQL executor that parses it fresh. No SET VARIABLE,
-- no getvariable — the value is a literal embedded in the dispatched string.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- extensions — hostfs (tree walk + path scalars), shellfs (the launch pipe),
-- tera (figures). INSTALL is idempotent; folded in here so provisioning is
-- ONE file, not a flag on a launcher. LOAD stays at each stage's point of use.
-- ---------------------------------------------------------------------------
INSTALL hostfs FROM community;
INSTALL shellfs FROM community;
INSTALL tera FROM community;

-- ---------------------------------------------------------------------------
-- policy — what enters the corpus. Edit these tables; the crawl reads them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE policy_skip_dirs (name VARCHAR);
INSERT INTO policy_skip_dirs VALUES
  ('node_modules'), ('.venv'), ('venv'), ('.git'), ('__pycache__'),
  ('site-packages'), ('.cache'), ('.cargo'), ('.npm'), ('.next'),
  ('target'), ('.pytest_cache'), ('.mypy_cache'), ('build'), ('dist'),
  ('vendor'), ('.ipynb_checkpoints'), ('coverage'), ('__snapshots__'),
  ('.idea'), ('.turbo'), ('generated'), ('migrations'), ('.terraform'),
  -- this repo's OWN runtime output — wave results, request/response logs, and
  -- prompt/output scratch — hold machine-generated files; self-crawling for the
  -- WRITEUP must not descend into them. Editing this list re-aims the crawl.
  ('catalog'), ('log'), ('out'), ('prompts');

CREATE OR REPLACE TABLE policy_exts (ext VARCHAR);
INSERT INTO policy_exts VALUES
  ('.md'), ('.markdown'), ('.mdx'), ('.txt'), ('.rst'), ('.org'),
  ('.sql'), ('.py'), ('.sh'), ('.js'), ('.ts'), ('.yaml'), ('.yml'), ('.toml');

-- ---------------------------------------------------------------------------
-- tasks — a task is a row: its instructions and ONE worked example entry.
-- The output contract is FIXED for every task — one entry per document,
-- {path, out: [strings]} — so ingest is task-agnostic and a new task is an
-- INSERT. The prompt architecture around these (role, rules, example,
-- delimited documents, contract restated after the documents with an exact
-- count) is harness-owned and lives, visibly, in sql/wave.sql.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE tasks (task VARCHAR, instructions VARCHAR, example VARCHAR);
INSERT INTO tasks VALUES
('summarize',
'Summarize each document for a technical reader deciding whether to open it.
out = exactly ONE string of 2-4 sentences that states: (1) what the document is, (2) what it does, covers, or claims, and (3) at least one concrete specific — a named function, table, endpoint, number, or decision that distinguishes THIS document from others like it.
Write plain declarative prose. Do not restate the file path, do not evaluate quality, do not hedge.',
'{"path": "/repo/jobs/nightly_rollup.sql", "out": ["Nightly aggregation job that rebuilds the store_day_rollup table from raw POS events. Deduplicates by receipt_id with a QUALIFY row_number window, then inserts day-grain totals per store. Notable: hard-codes a 3 AM America/Chicago cutoff and skips stores listed in ops_exclusions."]}'),
('distill',
'Extract the distinct IDEAS each document contains: technical designs, architectural decisions, doctrines and principles, hard-won lessons.
out = zero to eight strings, each "title — substance", where the substance is 1-2 sentences specific enough that an engineer who never saw the document could apply the idea.
An idea must be re-usable knowledge. These do NOT count: task lists and status updates, restatements of common practice ("write tests", "use version control"), tool inventories, anything you cannot point to in the text.
Prefer fewer, denser entries over exhaustive weak ones.',
'{"path": "/repo/notes/retry-design.md#s2", "out": ["Retry-After beats exponential guessing — when the server names its own delay in a Retry-After header, honor it verbatim and fall back to base_ms * attempt only when the header is absent; the doc measured 40% fewer wasted attempts.", "Bounded ladder as data — each retry attempt is a row produced by a gated CTE, so maximum depth is the number of CTEs, visible in the query text instead of hidden in a loop variable."]}'),
('classify',
'Assign each document exactly one label from this closed set:
  code           reusable source defining functions/macros/modules, meant to be imported or loaded
  script         an executable entrypoint meant to be RUN (run instructions, top-level statements, or a shebang)
  config         machine-read settings: keys and values consumed by a tool (CI, lockfiles, manifests)
  documentation  explains something to a human reader (READMEs, guides, references)
  prose          narrative writing that stands alone: notes, essays, write-ups, journals
  data           records or output: exports, logs, fixtures, generated listings
Tie-breaks: code vs script — script if invoked directly, code if loaded by something else. documentation vs prose — documentation explains an artifact that exists; prose stands alone. config vs data — config changes a tool''s behavior; data is consumed as content.
out = exactly ONE string "label — evidence", where the evidence cites a concrete marker from the document (a shebang, a Run: line, a heading, a key name).',
'{"path": "/repo/bin/refresh.sh", "out": ["script — shebang #!/usr/bin/env bash and top-level execution: it runs duckdb -f nightly.sql directly rather than defining reusable functions"]}');

-- ---------------------------------------------------------------------------
-- ledgers — one appended row per invocation, never rewritten. The latest
-- committed row IS the current parameters: stages read it, nothing sets
-- session state. (Concurrent waves in one working dir were never supported —
-- they collide on the prompts/ and out/ scratch before they'd collide here.)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crawls (root VARCHAR, started_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS runs (
  run_id VARCHAR, task VARCHAR, n_workers INT, batch_size INT,
  min_chars INT, max_chars INT, note VARCHAR, started_at TIMESTAMP);

-- placeholder corpus so the views below can bind on a fresh database;
-- sql/corpus.sql CREATE OR REPLACEs it with the real thing (src = the tier that
-- delivered each file, 'text' or the blob backstop).
CREATE TABLE IF NOT EXISTS corpus (
  signature VARCHAR, root VARCHAR, src VARCHAR, path VARCHAR, name VARCHAR, ext VARCHAR,
  size_bytes BIGINT, mtime TIMESTAMP, section INT, sections INT,
  wire_key VARCHAR, chars BIGINT, preview VARCHAR, content VARCHAR);

-- seed the sink FIRST (a zero-match glob passed to read_parquet is an ERROR,
-- not an empty set — the _seed partition keeps it non-empty; signature NULL
-- joins to nothing and counts in no task), THEN the view over it. glob() the
-- table function is the ONE right probe here: zero matches = zero rows, no
-- error, and unlike a directory check it cannot be fooled by COPY creating
-- its target dir eagerly for zero rows.
COPY (SELECT NULL::VARCHAR AS signature, NULL::VARCHAR AS task,
             NULL::VARCHAR AS out, NULL::VARCHAR AS worker,
             NULL::TIMESTAMP AS ts, NULL::VARCHAR AS path,
             NULL::TIMESTAMP AS mtime, NULL::INT AS section,
             '_seed' AS batch_sig
      WHERE (SELECT count(*) FROM glob('catalog/*/*.parquet')) = 0)
TO 'catalog' (FORMAT parquet, PARTITION_BY (batch_sig), APPEND);

-- catalog: the ONE result sink — append-only parquet partitions under
-- catalog/, one partition per worker batch. union_by_name: partitions
-- written by older schema versions read as NULLs, never as errors.
CREATE OR REPLACE VIEW catalog AS
  FROM read_parquet('catalog/*/*.parquet',
                    hive_partitioning := true, union_by_name := true);

-- results: the human read surface — the CURRENT corpus's rows, resolved.
CREATE OR REPLACE VIEW results AS
  SELECT cat.task, corpus.root, corpus.path, corpus.section, corpus.sections,
         from_json(cat.out, '["VARCHAR"]') AS out,
         cat.worker, cat.ts
  FROM catalog cat JOIN corpus ON cat.signature = corpus.signature;

-- history: every version of every document the catalog has EVER landed,
-- keyed by the echoed path + the mtime captured at ingest — it survives
-- corpus rebuilds, because the catalog rows are self-describing. Two rows,
-- same path, different signatures = the document changed between waves.
CREATE OR REPLACE VIEW history AS
  SELECT path, task, section, mtime, signature, out, worker, ts
  FROM catalog
  WHERE signature IS NOT NULL;

-- VALIDATION — expectations stated: 3 tasks, 14 policy exts, catalog readable.
SELECT (SELECT count(*) FROM tasks)       AS tasks,
       (SELECT count(*) FROM policy_exts) AS policy_exts,
       (SELECT count(*) FROM catalog)     AS catalog_rows;
