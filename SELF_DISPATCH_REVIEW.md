# Self-dispatch review

Repository: `asubbarao/duckstack` (origin).
Branch: `codex/self-dispatch-review`.
Checkout: `/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review`.
Comparison base: `48047f5f46f9475999ffaa25bac6427ba733ace2`.

This branch consolidates the Tera rewrite, examples, compendium, code-analysis recipes,
and keyed-write fixes. It does not deploy the changes. The shared source checkouts retain
their prior local edits; unrelated duck-hunt/change-impact/server-module work is excluded.

## What changed

- Generated replica SQL, route SQL, docs fetching, profile export and per-session ingestion
  use readable Tera substitutions. SQL owns decisions and execution; no new dispatch macros.
- Boot and cron use one complete transcript refresh body. Session grouping, JSON reader
  settings, mtime filtering and late DuckLake attachment are preserved.
- `pull_log`: key `(run_started, table_name)`, unique index, `INSERT OR IGNORE … BY NAME`.
  New schemas require non-null key columns. `run_id` remains a display label.
- `ext_fetch`: key `(url, fetched_at)`; snapshot-matching `MERGE … INSERT BY NAME`
  ignores an existing observation. DuckLake cannot enforce it with a unique index.
  The generated statement retains its timestamp when replayed.
- [Compendium](skills/self-dispatch/references/compendium.md),
  [actual-source review queries](skills/self-dispatch/references/review.sql), and
  [general code-analysis recipes](skills/query/references/code-analysis.sql).

## Verified

On dev, 2026-10-16:
- 2,840 ext_fetch rows and distinct keys; no duplicate or null keys.
- Same rendered fetch merged twice inside a transaction: one row; rollback removed it.
- Named find template: /private/tmp. Repeated seq/jq template: IDs 1, 2, 3.
- Generated profile COPY executed; file read back as the expected JSON.
- Four live session-copy candidates rendered and passed native SQL parsing.
- Replica pull body, route SELECT body, scheduled post and docs MERGE rendered and parsed.
- Native parser, Sitting Duck and Duck Tails were applied to the actual branch files.
  The native parser normalizes OR IGNORE as ON CONFLICT DO NOTHING.
- Git whitespace checks passed.

## Limits to review

The replica's 9511 listener and database file are absent, so its persisted duplicate/null
checks and live insert could not run. Existing duplicate keys will fail unique-index
creation visibly. CREATE TABLE IF NOT EXISTS does not retrofit NOT NULL onto a legacy
table; inspect legacy null keys before adopting it on another existing replica.

Whole setup files contain CLI/extension syntax outside parser_tools' grammar. Rendered
route SELECT SQL parses; CREATE ROUTE itself needs quackapi's parser. Sitting Duck emits
ERROR nodes for some valid DuckDB constructs, including the replica insert/struct syntax;
candidate identifiers and errors are retained rather than claiming exhaustive call discovery.

Full boot, scheduled transcript refresh and live replica copying were not run.
The docs MERGE ignores keys visible to its snapshot; it is not a global uniqueness constraint
against arbitrary concurrent writers. The existing daily source deduplicates URLs and partitions
them into disjoint batches.

## Review the complete branch

```sql
SELECT *
FROM git_diff_tree(
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review',
    '48047f5f46f9475999ffaa25bac6427ba733ace2',
    'codex/self-dispatch-review'
);
```

For each selected file, use a literal native comparison (old first, new second):

```sql
SELECT *
FROM read_git_diff(
    'git:///Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/setup.sql@48047f5f46f9475999ffaa25bac6427ba733ace2',
    'git:///Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/setup.sql@codex/self-dispatch-review'
);
```

For added files, use `/dev/null` as the old side. Run native diff calls individually on
this installed build; the earlier UNION ALL combination lost Quack connections.
