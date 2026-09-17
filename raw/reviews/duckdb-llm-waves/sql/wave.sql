-- ============================================================================
-- wave.sql — prompts -> launch -> ingest. One file, one session. Parameters
-- are the latest committed runs row: each stage opens with a one-line CTE
-- (QUALIFY row_number() = 1, latest by started_at) — NO SET VARIABLE, no
-- getvariable, reading a ledger row is a plain query. An empty ledger yields
-- zero rows, so every stage no-ops instead of NULL-joining. The row's run_id
-- is the wave's identity everywhere: the runs ledger and both log/ partitions.
-- ============================================================================

LOAD hostfs;
LOAD shellfs;

-- ============================================================================
-- PROMPTS — assembled in the open; nothing is a macro. pending is written as
-- what it is: corpus ANTI JOIN catalog for this run's task. Assignment is
-- hash(signature) % n_workers; each worker's batch is a QUALIFY row_number
-- cap. The prompt structure is the boring, load-bearing one for
-- schema-constrained extraction:
--   - a role preamble that names the parser ("parsed by a SQL join"),
--   - the task's instructions (a row in tasks),
--   - hard rules: verbatim wire keys, exact entry count, out: [] sanctioned,
--   - ONE worked example entry (a row in tasks),
--   - the delimited documents with an explicit count,
--   - the contract RESTATED after the documents — long-input models weight
--     the ends of the context, so the contract brackets the batch.
-- The min_chars..max_chars band bounds one worker's prompt; oversize files
-- were already sectioned by the corpus, so the band is a rail, not a hole.
-- ============================================================================

CREATE OR REPLACE TABLE prompt_stage AS
WITH run AS (SELECT * FROM runs QUALIFY row_number() OVER (ORDER BY started_at DESC, run_id DESC) = 1),
tsk AS (SELECT t.instructions, t.example FROM tasks t JOIN run USING (task)),
done AS (
  SELECT DISTINCT cat.signature
  FROM catalog cat JOIN run ON cat.task = run.task
),
pending AS (
  SELECT c.signature, c.wire_key, c.content,
         run.run_id, run.task, run.n_workers, run.batch_size
  FROM corpus c
  CROSS JOIN run
  ANTI JOIN done USING (signature)
  WHERE c.chars BETWEEN run.min_chars AND run.max_chars
),
batched AS (
  SELECT *, hash(signature) % n_workers AS k
  FROM pending
  QUALIFY row_number() OVER (PARTITION BY hash(signature) % n_workers
                             ORDER BY hash(signature)) <= batch_size
),
assembled AS (
  SELECT run_id, task, k,
         count(*) AS n_docs,
         string_agg(format(E'=== FILE: {} ===\n{}', wire_key, content),
                    E'\n\n' ORDER BY hash(signature)) AS docs
  FROM batched
  GROUP BY run_id, task, k
)
SELECT a.run_id, a.task, a.k,
       format('worker_{}', a.k) AS worker,
       a.n_docs,
       format(
E'You are an extraction worker inside a database-orchestrated pipeline. Your output is parsed by a SQL join, not read by a human: return ONLY a JSON object matching the schema you were given — no prose, no markdown fences, no commentary.

TASK
{}

RULES
- Return EXACTLY one entry per document: {} documents -> {} entries in "files".
- Copy "path" VERBATIM from the document''s === FILE: header — byte-for-byte, including any #sN suffix. A modified path destroys the row.
- Ground every output string in the document''s text. Never invent, never import outside knowledge, never pad with filler.
- If the task yields nothing for a document, return "out": [] for it — do not omit the entry, do not manufacture content.
- Some documents are sections of a larger file (header ends in #sN); treat each section as a complete, standalone unit of work.

EXAMPLE ENTRY (for a document not in this batch)
{}

DOCUMENTS ({})
{}

END OF DOCUMENTS
Return the JSON object now: exactly {} entries in "files", each "path" copied verbatim from a header above.',
         t.instructions, a.n_docs, a.n_docs, t.example, a.n_docs, a.docs,
         a.n_docs) AS prompt
FROM assembled a CROSS JOIN tsk t;

-- worker k's whole prompt lands at prompts/k=<k>/*.csv — raw text (QUOTE ''
-- ESCAPE ''), OVERWRITE so a smaller wave never inherits stale shard dirs.
-- prompts/ is CLI transport scratch; the log below is what survives.
COPY (SELECT k, prompt FROM prompt_stage)
TO 'prompts' (FORMAT csv, QUOTE '', ESCAPE '', HEADER false,
              PARTITION_BY (k), OVERWRITE);

-- THE LOG IS THE SYSTEM: the verbatim request, appended before anything
-- launches. Requests and responses are rows of ONE relation split by the
-- kind partition; md5(body) is content identity — "have I sent this exact
-- prompt before" is a join over the log, never a memory. (The scratch file
-- carries one extra trailing newline over these bytes.)
COPY (
  SELECT 'request'        AS kind,
         run_id           AS wave_sig,
         worker, task,
         prompt           AS body,
         md5(prompt)      AS body_sig,
         now()::TIMESTAMP AS ts
  FROM prompt_stage
) TO 'log' (FORMAT parquet, PARTITION_BY (kind, wave_sig), APPEND);

-- VALIDATION — one line per launched worker. files_in_prompt re-counts the
-- newline-prefixed headers in the ASSEMBLED TEXT and MUST equal n_docs — a
-- disagreement means a document's own content collided with the header
-- delimiter.
SELECT k, n_docs,
       length(prompt) AS prompt_chars,
       len(string_split(prompt, E'\n=== FILE: ')) - 1 AS files_in_prompt
FROM prompt_stage
ORDER BY k;

DROP TABLE prompt_stage;

-- ============================================================================
-- LAUNCH — launching LLMs is a query. Nothing is written to disk but the prompts: the
-- worker commands are generated by an inner duckdb over the prompt files ON DISK (what
-- launches is what EXISTS) and piped straight into bash; scanning the one row from that
-- constant shellfs pipe IS the launch, the parallelism, and the barrier — the row arrives
-- when `wait` returns. The LLM CLI and the JSON contract sit in plain sight; swap the CLI
-- here. The _empty.json floor keeps ingest's out/*.json glob non-empty when nothing ran.
-- ============================================================================
LOAD shellfs;
-- the JSON contract is a file the workers read, so no quote nests inside the launch line
COPY (SELECT '{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"out":{"type":"array","items":{"type":"string"}}},"required":["path","out"]}}},"required":["files"]}' AS schema)
TO 'prompts/schema.json' (FORMAT csv, QUOTE '', ESCAPE '', HEADER false);

-- the inner duckdb is single-quoted so the outer shell expands nothing; its SQL strings are
-- dollar-quoted so the commands read as commands. One line per prompt file, then wait.
SELECT trim(workers_done) AS workers_done
FROM read_csv($p$duckdb :memory: -csv -noheader -c 'LOAD hostfs; COPY (
  SELECT $s$mkdir -p out && rm -f out/*.json$s$
  UNION ALL
  SELECT format($s$grok -p "$(cat {})" --json-schema "$(cat prompts/schema.json)" > out/worker_{}.json 2>/dev/null &$s$,
                absolute_path(path), replace(file_name(parse_dirpath(path)), $s$k=$s$, $s$$s$))
  FROM lsr($s$prompts$s$) WHERE is_file(path) AND file_extension(path) = $s$.csv$s$
  UNION ALL SELECT $s$wait; ls out | wc -l$s$
) TO $s$/dev/stdout$s$ (FORMAT csv, QUOTE $s$$s$, ESCAPE $s$$s$, HEADER false)' | bash 2>/dev/null |$p$,
              header := false, columns := {'workers_done': 'VARCHAR'});

-- the floor: keeps ingest's out/*.json glob non-empty when nothing was pending
COPY (SELECT '{"files":[]}' AS j) TO 'out/_empty.json' (FORMAT csv, QUOTE '', ESCAPE '', HEADER false);

-- ============================================================================
-- INGEST — land worker outputs in the append-only catalog. One COPY APPEND,
-- PARTITION_BY (batch_sig): each worker file gets ONE fresh batch_sig, so
-- concurrent and future waves land in their own partition dirs of the ONE
-- sink — no locks, no coordination. The join back to the corpus is BY
-- ECHOED WIRE KEY: the worker echoes it verbatim from its === FILE: header
-- (path, or path#sN for a section), so a mangled key surfaces as a join
-- miss in the validation tail — listed, never silently dropped.
--
-- Landed rows carry path + mtime + section alongside the signature: the
-- catalog is SELF-DESCRIBING, so version history (same path, different
-- signatures over time) survives any number of corpus rebuilds.
--
-- Envelope-agnostic: grok --json-schema wraps the validated object under
-- .structuredOutput; a bare {files:[...]} (claude -p and friends) parses via
-- the second shape. from_json is lenient — a non-matching shape yields NULL,
-- COALESCE picks the one that matched.
-- ============================================================================

-- Verbatim response bytes, appended BEFORE any parsing (and before the next
-- wave's launch recycles out/): the raw worker output survives even if the
-- parse shapes change later. _empty.json is the launch glob's floor
-- sentinel, not a response — the only row excluded.
COPY (
  WITH run AS (SELECT * FROM runs QUALIFY row_number() OVER (ORDER BY started_at DESC, run_id DESC) = 1)
  SELECT 'response'                                     AS kind,
         run.run_id                                     AS wave_sig,
         replace(parse_filename(filename), '.json', '') AS worker,
         run.task                                       AS task,
         content                                        AS body,
         md5(content)                                   AS body_sig,
         now()::TIMESTAMP                               AS ts
  FROM read_text('out/*.json')
  CROSS JOIN run
  WHERE parse_filename(filename) != '_empty.json'
) TO 'log' (FORMAT parquet, PARTITION_BY (kind, wave_sig), APPEND);

CREATE OR REPLACE TABLE wave_stage AS
WITH run AS (SELECT * FROM runs QUALIFY row_number() OVER (ORDER BY started_at DESC, run_id DESC) = 1),
parsed AS (
  SELECT filename,
         unnest(COALESCE(
           from_json(content, '{"structuredOutput":{"files":[{"path":"VARCHAR","out":["VARCHAR"]}]}}').structuredOutput.files,
           from_json(content, '{"files":[{"path":"VARCHAR","out":["VARCHAR"]}]}').files
         )) AS entry
  FROM read_text('out/*.json')
  WHERE length(content) > 0          -- a crashed worker leaves an empty file: logged above, not parsed
),
sigs AS (
  SELECT filename, uuid()::VARCHAR AS batch_sig
  FROM (SELECT DISTINCT filename FROM parsed)
)
SELECT s.batch_sig,
       corpus.signature                                 AS signature,
       run.task                                         AS task,
       to_json((p.entry).out)::VARCHAR                  AS out,
       replace(parse_filename(p.filename), '.json', '') AS worker,
       now()::TIMESTAMP                                 AS ts,  -- plain TIMESTAMP: TIMESTAMPTZ would fork the sink's schema
       corpus.path                                      AS path,
       corpus.mtime::TIMESTAMP                          AS mtime,
       corpus.section                                   AS section,
       (p.entry).path                                   AS echoed_key
FROM parsed p
CROSS JOIN run
JOIN sigs s USING (filename)
LEFT JOIN corpus ON corpus.wire_key = (p.entry).path;

COPY (SELECT batch_sig, signature, task, out, worker, ts, path, mtime, section
      FROM wave_stage WHERE signature IS NOT NULL)
TO 'catalog' (FORMAT parquet, PARTITION_BY (batch_sig), APPEND);

-- VALIDATION — join_misses MUST be 0 (a miss = a worker mangled a wire key;
-- it is listed by name, never silently lost). pending_after is the burn-down:
-- the ANTI JOIN, written where it is used.
WITH run AS (SELECT * FROM runs QUALIFY row_number() OVER (ORDER BY started_at DESC, run_id DESC) = 1)
SELECT (SELECT count(*) FROM wave_stage)                          AS entries,
       (SELECT count(*) FILTER (WHERE signature IS NULL)
          FROM wave_stage)                                        AS join_misses,
       (SELECT list(echoed_key) FILTER (WHERE signature IS NULL)
          FROM wave_stage)                                        AS missed_keys,
       (SELECT count(*)
          FROM corpus
          ANTI JOIN (SELECT cat.signature
                     FROM catalog cat JOIN run ON cat.task = run.task) done
          USING (signature))                                      AS pending_after
FROM run;

DROP TABLE wave_stage;
