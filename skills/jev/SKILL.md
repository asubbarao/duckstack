---
name: jev
description: Add semantic judgments to DuckDB rows with the JEV community extension, and inspect stored judgments against labelled examples.
---

JEV asks a model about each input row. Use it when SQL can select candidates but cannot decide their meaning. Keep source IDs, context, raw answers and errors so each judgment remains inspectable.

Use the selected DuckDB service: dev is http://localhost:9495/mcp/, with http://localhost:9495/sql as its fallback. Start with a bounded SELECT over existing data or a file reader. Install and load with `INSTALL jev FROM community; LOAD jev;`.

Read [useful_queries.sql](references/useful_queries.sql) for the compact working example and [explain.sql](references/explain.sql) for binding checks. Show the core declarative operation clearly: source rows become rows with semantic companion columns, or explicit pairs receive relationship judgments. Prefer under 100 lines, around 50 for a skeleton; 100–200 lines can be justified by real primary-dataset preparation. Explain the need for length rather than hiding complexity in the first CTE. Put EXPLAIN plans in a separate file. Use direct SELECT or file input, without VALUES clauses or fixture tables. Inspect schemas with DESCRIBE and profiles with SUMMARIZE. Preserve detail with array_agg when grouping is needed; avoid COUNT FILTER and custom lossy metric summaries. Use finetype for local type detection and fakeit when generated input earns its place; preserve generated rows for repeatable comparisons.

Start with a plain SELECT that returns the useful judgments. COPY is an optional later persistence step, not part of the core example. On the selected dev Quack service, SET jev_max_rows_per_statement was rejected because configuration is locked (2026-09-29); select a bounded source before inference instead. Read nonsecret settings through duckdb_settings() filtered to named fields; current_setting('jev_api_key') errored on the installed build. Never print credential values.

## Pick the answer shape

- `jev_prob(input, question)` returns a probability; `jev(input, question, threshold)` returns a Boolean decision.
- `jev_choice(input, question, options)` returns one fixed label. Make options disjoint and include insufficient evidence when needed.
- `jev_score` returns an ordered position; `jev_score_norm` rescales it to 0..1. This is an ordered score, not a probability.
- `jev_eval(input, question [, kind [, options]])` returns raw JSON. Preserve it before extracting fields.
- `jev_confidence(input, question, kind, options)` describes choice/score certainty; match the question and options used for the answer.

Community JEV accepts a scalar or structured row. Send meaningful content, leaving identifiers and human labels outside the model input. NULL input returns NULL without inference; a struct containing NULL fields is still a struct. Keep missing input and failed inference as unknown.

Select a small candidate set before inference: a LIMIT after ordering model results does not bound requests. Store successful answers once with source/context identity, question/options version, effective model/endpoint and evaluation time. Reuse stored answers for later inspection; changing a threshold should not call the model again. Preserve uncertain request receipts and investigate before retrying paid inference.

## Evaluate stored answers

Join a fixed human-labelled sample to stored answers by stable IDs. Inspect row-level truth, prediction, probability, missing answer and error together; use DESCRIBE/SUMMARIZE for profiling. Retain disagreement and missing-answer rows as the review queue. Keep prompt development examples separate from held-out examples. For matching tasks, inspect missed candidates separately from incorrect judgments.

Only produce numerical accuracy or threshold comparisons when requested, with their definition and contributing source rows retained. Missing answers must remain visible. Handwritten predictions verify SQL mechanics, not model quality; no live model accuracy was measured in the initial exploration.

## Credentials and verified limits

Initial dev checks on 2026-09-29 used DuckDB v1.5.5 and JEV 0.1.0, artifact 58e5484. Install/load, signatures, NULL behavior and inference EXPLAIN binding succeeded. The selected host lacked a TypeSafe credential, so actual inference, accuracy and throughput remain unverified. Check credential presence without printing its value. A key in a client process does not configure an already-running service; use the selected host's credential path when supplied.

The inspected community artifact caches by question/options/input but omits model, endpoint and credential namespace. This can reuse answers across configurations. See [cache-fix.md](references/cache-fix.md) for current repair evidence and upstream status; a tested local patch does not change the installed community artifact. Avoid shared cache clearing during comparisons; use an explicitly owned isolated runtime if needed.

Community failures can abort a query after some answers were cached. Request guards apply to individual bound function calls, not a whole statement or daily budget. `jev_stats` is process-wide; its estimated cost and counter differences are not billing receipts or isolated measurements.

MotherDuck `prompt_jev` is a separate runtime and API, not installed by local JEV. Use its current [API documentation](https://motherduck.com/docs/sql-reference/motherduck-sql-reference/ai-functions/prompt-jev/) only when MotherDuck is explicitly selected. No MotherDuck execution was verified here.

Read [backend-fit.md](references/backend-fit.md) only for proposed InFrame applications. They are source-based ideas, not implemented integrations.

Sources: [DuckDB introduction](https://duckdb.org/2026/09/29/jev), [community interface](https://duckdb.org/community_extensions/extensions/jev), [inspected source](https://github.com/judoaseeta/duckdb-jev/tree/58e548463b0bfb25d86bc68b11515a1daaf87ab3).

