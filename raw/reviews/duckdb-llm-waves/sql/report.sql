-- ============================================================================
-- report.sql — coverage per task, then the latest wave's results. No
-- parameters: coverage is always all tasks, and per-task filtering is what
-- ad-hoc queries over the results view are for.
-- ============================================================================
-- done counts DISTINCT corpus-joined signatures: catalog rows for units no
-- longer in the corpus (old versions, racing double-lands) never inflate it —
-- this is the pending ANTI JOIN, counted from the other side.

SELECT t.task,
       (SELECT count(*) FROM corpus)                       AS corpus_units,
       count(DISTINCT corpus.signature)                    AS done,
       (SELECT count(*) FROM corpus)
         - count(DISTINCT corpus.signature)                AS pending
FROM tasks t
LEFT JOIN catalog cat ON cat.task = t.task
LEFT JOIN corpus ON corpus.signature = cat.signature
GROUP BY t.task
ORDER BY t.task;

-- what the most recent wave landed, resolved against the current corpus.
WITH run AS (SELECT * FROM runs QUALIFY row_number() OVER (ORDER BY started_at DESC, run_id DESC) = 1)
SELECT r.task, r.path, r.section, r.out
FROM results r
JOIN run ON r.task = run.task AND r.ts >= run.started_at
ORDER BY r.path, r.section;
