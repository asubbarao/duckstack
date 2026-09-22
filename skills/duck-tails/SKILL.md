---
name: duck-tails
description: >
  A git repository as a filesystem, not just as a log. `LOAD duck_tails` registers the `git://`
  filesystem, and **every DuckDB reader works over it — including Parquet** (verified: 66
  hive-partitioned Parquet blobs read straight out of a commit, hive keys intact, `parquet_metadata`
  and all). The history tables (`git_log`, `git_tree`, `git_read`, `git_status`, blame, diffs) are
  the other half. Use when asked to read a repo at a revision, read data committed to a repo,
  compare a dataset across commits, inventory what a repo contains, or when about to shell out to
  `git show`/`git archive` to get a file's bytes. Read `/duckstack:duck` first — its SQL process
  rules apply to git data too.
argument-hint: "<repo path> [file | ref | question]"
allowed-tools: Bash
---

Most agents reach for `duck_tails` as "git log as a table" and stop there. That is the small half.
The load-bearing fact is that `git://` is a **DuckDB filesystem**: a commit is a directory tree
that readers can glob, seek into, and hive-partition. `git://data/**/*.parquet@HEAD~5` is a
dataset as of five commits ago, with no checkout, no `git show >` to a temp file, and no
second language in the data path.

`/duckstack:git-github` is the companion: `gh` for **remote** GitHub, `gh` CLI for private repos.
This skill is the **local** repository, and it corrects three things `git-github` states wrongly.

## 1. The rule that decides everything

`LOAD duck_tails` registers `git://`. **Autoload does not fire for it.** Without the `LOAD`, the
failure is not "unknown filesystem" — it is a misleading path error you will waste minutes on
(verified 2026-09-18):

```
IO Error: No files found that match the pattern "git://platform/.../carriers.csv@HEAD"
```

Two spellings, both verified, both usable from any working directory:

| Form | When |
|---|---|
| `git://<path-relative-to-repo-root>@<ref>` | cwd is inside the repo |
| `git:///<abs-repo-path>/<path>@<ref>` | anywhere — this is exactly what `git_tree`'s `git_uri` column hands you |

`<ref>` is anything git resolves: `HEAD`, `HEAD~1`, a branch, a tag, a full or short SHA. The
argument binds at parse time, so a literal, `getenv()`, `getvariable()` or pure concatenation of
those is fine — **a column is not** (see §5).

## 2. Parquet: yes. Verified, not inferred

The question "can `duck_tails` read Parquet?" is answered by running it. Corpus: 66
hive-partitioned Parquet files committed to a real repo (`nlp_findings`, one commit `f7179e7`),
`/…/scratchpad/readrepos/nlp_findings/nlp_sessions_archaeology/findings/<family>/signature=<hash>/<uuid>.parquet`.

```bash
export CORPUS_REPO=/private/tmp/claude-501/-Users-aloksubbarao-inframe/37bb1b7c-d200-4459-a2bf-637b6d8daba2/scratchpad/readrepos/nlp_findings
duckdb :memory: -f duck_tails_parquet.sql
```

```sql
LOAD duck_tails;

-- git_tree(repo_path, ref, "array" := NULL, untracked := false)
--   repo_path and ref are POSITIONAL in that order (neither is a named parameter);
--   one arg means repo and ref defaults to HEAD
CREATE OR REPLACE VIEW bank_blobs AS
SELECT git_uri, file_path, file_ext, kind, is_text, encoding, size_bytes, blob_hash, commit_hash, ref
FROM git_tree(getenv('CORPUS_REPO'), 'HEAD');

SELECT file_ext, kind, encoding,
       array_agg(DISTINCT is_text) AS is_text_values,
       len(array_agg(file_path))   AS n_blobs
FROM bank_blobs
WHERE file_ext = '.parquet'
GROUP BY ALL;
-- .parquet | file | binary | [false] | 66

-- read_parquet(path, binary_as_string := false, filename := false, file_row_number := false,
--              hive_partitioning := auto, hive_types_autocast := true, union_by_name := false)
CREATE OR REPLACE VIEW bank AS
SELECT *
FROM read_parquet('git://' || getenv('CORPUS_REPO')
                  || '/nlp_sessions_archaeology/findings/**/*.parquet@HEAD',
                  union_by_name := true, filename := true);

DESCRIBE bank;

SELECT agent_angle,
       array_agg(DISTINCT query_name ORDER BY query_name) AS query_names, len(query_names) AS n_queries,
       len(array_agg(DISTINCT signature))                 AS n_signatures,
       len(array_agg(DISTINCT filename))                  AS n_blobs
FROM bank
GROUP BY ALL
ORDER BY agent_angle;
```

What that run actually proved (2026-09-18, `duck_tails` 742af7b, DuckDB 1.5.5 osx_arm64):

| Claim | Evidence |
|---|---|
| Readers work over `git://` | `DESCRIBE bank` → 28 typed columns; 138,336 distinct `row_id`s across all 66 blobs |
| Globs resolve inside a commit | `**/*.parquet@HEAD` → 66 files, 11 families, no file list written by hand |
| **Hive keys survive** | `signature` is a column; set `hive_partitioning := false` and it **disappears** — it is derived from the `git://` path, not stored in the file |
| `union_by_name` folds heterogeneous schemas | 11 families with different columns land in one relation |
| It is real random access, not a blob slurp | `parquet_metadata('git://…@HEAD')` → `SNAPPY`, 1 row group. The footer is seeked, then the row group |
| A ref is a real coordinate | `…@f7179e7da8432…` and `…@HEAD` both bind |

**Time travel over a reader, on a file that actually changed** — same path, two refs, in the
InFrame repo:

```sql
LOAD duck_tails;
-- read_csv(path, header := auto, delim := auto, all_varchar := false, sample_size := 20480, ...)
SELECT 'HEAD'  AS ref, len(array_agg(DISTINCT name)) AS n_carriers
FROM read_csv('git://platform/backend/app/alembic/data/carriers.csv@HEAD', header := true, all_varchar := true)
UNION ALL BY NAME
SELECT 'first' AS ref, len(array_agg(DISTINCT name)) AS n_carriers
FROM read_csv('git://platform/backend/app/alembic/data/carriers.csv@<first-sha>', header := true, all_varchar := true);
-- HEAD 6432 | first 964
```

That is the whole point: **a dataset's history is a `WHERE ref = …`, not a checkout.**

Caveat stated plainly: the 66-blob corpus has exactly **one commit**, so there is no earlier
revision of it to diff. The revision mechanism is proved on `carriers.csv` above, and the
Parquet reading is proved on the corpus. Neither claim leans on the other.

## 3. Verified facts — three of which contradict `/duckstack:git-github`

All checked 2026-09-18 against `duck_tails` 742af7b on DuckDB 1.5.5.

| Fact | Why it bites |
|---|---|
| `git_tree`'s positional order is **`(repo_path, ref)`** | `git-github` documents `git_tree(ref, repo_path)`. `git_tree('HEAD','.')` fails: *"Failed to resolve ref '.'"* |
| `repo_path` is **not a named parameter of `git_tree`** | It **is** for `git_log` and `git_blame`. `git_tree('.', repo_path := '.')` → *Binder Error: Invalid named parameter* |
| `git_status` takes the repo **positionally only**; its `path` parameter is a **pathspec filter** | `git_status(repo_path := '.')` → Binder Error; `git_status(path := '.')` returns **zero rows**, not the repo |
| `file_ext` **carries the leading dot**: `.sql`, `.parquet`, `''` for `LICENSE` | `git-github`'s `WHERE file_ext = 'sql'` returns **0 rows**, silently |
| `git_tree` returns directories too — `kind IN ('tree','file')` | On this fork: 21 trees, 28 files. Un-filtered inventories double-count |
| `"array" := [...]` is accepted but **ignored** | It needs quoting (`array` is a keyword) and then does not narrow the tree — 49 rows with or without it. Filter in `WHERE` |
| `COPY … TO 'git://…'` raises an **INTERNAL Error** — native stack trace, *"assertion failure within DuckDB"* — not a clean read-only refusal | The rest of the statement chain never runs. `git://` is read-only: write to a real path and commit with `git` |
| `git_read` returns **both** `text VARCHAR` and `blob BLOB` | Binary file → `text` is NULL, `blob` holds all bytes, `encoding = 'binary'`, `truncated = false`. Verified: 154,384 bytes of Parquet |
| `git_uri` is a column on `git_tree`/`git_read` **and** a scalar | `git:///abs/repo/path@<full-sha>` — feed it straight back to any reader |
| Autoload does not register `git://` | §1 |

## 4. The relations

```sql
LOAD duck_tails;

-- git_log(repo_path := '.')  -> repo_path, commit_hash, author_name, author_email, committer_name,
--                               committer_email, author_date, commit_date, message, parent_count, tree_hash
FROM git_log(repo_path := '.');

-- git_tree(repo_path, ref)  -- both POSITIONAL; ref defaults to HEAD
--                            -> git_uri, repo_path, commit_hash, tree_hash, file_path, file_ext,
--                               ref, blob_hash, commit_date, mode, size_bytes, kind, is_text, encoding
FROM git_tree('.', 'HEAD') WHERE kind = 'file';

-- git_read(path_or_uri, repo_path := '.')  -> git_uri, repo_path, commit_hash, tree_hash, file_path,
--                               file_ext, ref, blob_hash, mode, kind, is_text, encoding, size_bytes,
--                               truncated, text, blob
FROM git_read('README.md');

-- git_status(repo_path, path := NULL, ignored := false, untracked := true)  -- repo is POSITIONAL
--                            -> repo_path, file_path, file_ext, status, status_flags, staged, unstaged, old_path
FROM git_status('.');

-- git_blame(file, repo_path := '.', revision := 'HEAD', use_mailmap, first_parent,
--           ignore_whitespace, min_line, max_line)
--                            -> repo_path, file_path, file_ext, revision, line_number, line_content,
--                               commit_hash, author_name, author_email, author_date,
--                               orig_commit_hash, orig_path, orig_line_number, boundary
FROM git_blame('README.md', repo_path := '.');

-- read_git_diff(uri_a, uri_b)  -> diff_text, path1, path2
FROM read_git_diff('git://README.md@HEAD', 'git://README.md@HEAD~1');
```

Also present: `git_branches`, `git_tags`, `git_parents`, `git_diff_tree`, `git_blame_hunks`,
`text_diff`, `text_diff_lines`, `text_diff_stats`, `diff_text`.

## 5. Many files — the correlated form, and the wall

Every relation has an `_each` twin that **takes a column**. This is the correlated form and the
only legal way to fan out; verified reading all 19 `.md` files of this fork in one statement:

```sql
LOAD duck_tails;
SELECT len(array_agg(DISTINCT r.file_path)) AS n_files, len(array_agg(r.text)) AS n_texts
FROM (SELECT file_path FROM git_tree('.', 'HEAD') WHERE file_ext = '.md' AND kind = 'file') t,
     git_read_each(t.file_path) r;
-- 19 | 19
```

`git_read_each`, `git_tree_each`, `git_log_each`, `git_blame_each`, `git_status_each`,
`git_branches_each`, `git_tags_each`, `git_parents_each`, `git_diff_tree_each`.

**The wall:** `read_parquet`, `read_csv`, `read_json` and friends have **no `_each`**. A
`git_uri` sitting in a column cannot be handed to them — *"does not support lateral join column
parameters"*. Options, in order: a glob (`git://dir/**/*.parquet@HEAD` covers most cases); a
literal list `read_parquet(['git://a@HEAD','git://b@HEAD'])`; then `/duckstack:self-dispatch`.
Never a loop, a macro or a shell script.

## 6. House style — what the reference SQL teaches, and what `duck_tails` deletes

Source: `asubbarao/origin-agents-take-home`, `sql/` (`laws.sql`, `scan_and_audit.sql`,
`llm_audit.sql`, `misses.sql`, `personal_ext_usage.sql`, `ext_file_cluster.sql`,
`ext_catalog_capability.sql`, `ast_*`). These are working queries, not examples; match them.

1. **Files → unmaterialized views → tables only where compute is expensive.** `scan_and_audit.sql`
   states the layer model in its header: base tables are what an outside process appends; **views
   are the interface** agents read; a table appears only when the compute justifies it (its own
   scan stays a live view). `laws.sql` is CSV → views, nothing else.
2. **`row_number()` on every face; evidence as ordered `array_agg`; never a count as identity.**
   Their words: *"add cols, row_number, ordered arrays — no count laundry as identity."*
   `misses.sql` carries the whole shape: `array_agg(case_id ORDER BY case_id) FILTER (WHERE cell = 'FN') AS fn_ids`.
   The list is the fact; the number is `len(...)` of it.
3. **Window AFTER `GROUP BY`** — stated twice as a Duck constraint, because DuckDB forbids
   grouping on a window expression. The shape is always
   `SELECT *, row_number() OVER (…) FROM (SELECT … GROUP BY ALL)`.
4. **No regex, no `LIKE` laundry** — annotated in the files themselves (*"not LIKE laundry"*,
   *"no regex laundry"*, *"AST call graph only — no `rg`/string grep"*). The substitutes they
   actually use: `position(phrase IN hay) > 0`, `starts_with(upper(trim(line)), 'LOAD ')`,
   `array_intersect(tokens, [...])`, `list_has_any(path_split(path), [...])`, `marisa_lookup(trie, name)`.
5. **Selectors are rows.** `ext_file_cluster.sql` keeps a `function_name → extension_name` seed
   relation and joins it to file bodies with `position(s.function_name || '(' IN b.body) > 0`.
   The thing being looked for is data, never a hand-written predicate per case.
6. **The header comment is part of the deliverable** — what the file is, its grain, how to run it,
   what it writes, and an honest **soft-fail** section naming what did *not* work:
   *"`parse_functions` TABLE form is literal-only → cannot lateral over bodies"*;
   *"`fts` `PRAGMA create_fts_index` fails on this DuckDB CLI … `marisa` used as the 5th surface instead."*
   A working query plus a named limitation beats a claim.
7. **An extension earns its place through a function actually used.** `_ext_scorecard` is a
   relation of `extension_name, unique_fn, earned BOOLEAN, why` — a claim a reader can check.
8. **The bank.** `ast_killstreak_bank.sql` packs `query_text` beside `query_result` and writes
   `COPY … PARTITION_BY (agent_signature) OVERWRITE_OR_IGNORE`. The corpus in §2 is exactly that
   shape — `query_name`, `query_sql`, `comment`, `agent_angle` plus the result rows, hive-partitioned
   by `signature`. Reading it through `git://` is a bank being read back at a revision.
9. **The literal-only TVF wall is named in three separate files** — *"TVFs cannot take subqueries"*,
   *"parse_functions is literal-only → do NOT lateral it"*, *"COPY TO rejects expressions"*. §5.

**What `duck_tails` deletes from those files.** `personal_ext_usage.sql` and `ext_file_cluster.sql`
both inventory source by walking the working tree with `hostfs` `lsr` and then pruning by hand:

```sql
WHERE NOT is_dir(path) AND file_extension(path) = '.sql'
  AND NOT list_has_any(path_split(path),
        ['node_modules', '.git', 'clones', '.duckdb_home', '__pycache__', 'dump', 'dist', 'build'])
```

A commit tree has no untracked noise in it, so the prune list is not needed at all:

```sql
LOAD duck_tails;
-- git_tree(repo_path, ref): tracked blobs only, at a revision, with size and hash as columns
SELECT file_ext,
       array_agg(file_path  ORDER BY file_path) AS paths, len(paths) AS n_files,
       array_agg(size_bytes ORDER BY file_path) AS sizes
FROM git_tree('.', 'HEAD')
WHERE kind = 'file'
GROUP BY ALL
ORDER BY n_files DESC;
```

Same for the enumeration those files fall back on for a display name —
`string_split(m.file_path, '/')[-1] AS file` in `ast_killstreak_bank.sql`, and
`split_part`-style path surgery generally. `git_tree` and `git_read` already return `file_path`,
`file_ext`, `blob_hash`, `size_bytes`, `is_text`, `encoding` and `git_uri` **as named columns**;
select by name and the string surgery disappears. Hive keys under `git://` arrive the same way
(§2) — never recovered from the path by hand.

## 7. What it does not do

- **No writes.** `git://` is read-only, and `COPY … TO` it raises an INTERNAL Error that stops the
  statement chain (§3). Producing a commit is `git`'s job, outside the query.
- **No remotes.** Local object store only — a ref must already be fetched. Remote GitHub is
  `/duckstack:git-github` (`gh` extension for public, `gh` CLI for private).
- **Selected process only.** Inspect `duckdb_extensions()` and `duckdb_functions()` in the
  process selected for this task. For System Quack, install/load `duck_tails` through native MCP
  when needed, then persist a result with a complete `duckdb.quack_query(sql)` body. Do not infer
  service availability from a local CLI extension cache.
