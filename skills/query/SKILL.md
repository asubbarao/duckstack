---
name: query
description: >
  Run SQL through the selected DuckDB MCP. If unavailable in the harness, use the same
  service's QuackAPI endpoint or quack_query. Explore with queries; save reusable SQL.
argument-hint: <SQL | question | path.sql> [--door dev|quack:host:port]
allowed-tools: Bash, mcp__dev__query_with_limit, mcp__dev__query_no_limit
---

# Query the selected service

Read /duckstack:agent-door for the endpoint and /duckstack:duck for SQL rules.
For dev, prefer its MCP at http://localhost:9496/mcp: query for SELECT, sql for
DDL/DML or an ordered multi-statement body. Use task tools such as stream_recent,
stream_search, read_lines and ext_docs when they fit.

query/sql are primary execution tools: complete SQL bodies go through QuackAPI
to the same Quack server, including filesystem readers, ShellFS host commands,
HTTP and authorized writes. They return HTTP status/reason plus the full raw
response. The final SELECT defaults to 20 rows unless it has an explicit
outer LIMIT (including LIMIT ALL). Writes are never row-limited. parser_tools
splits statements; DuckDB's SELECT AST identifies limits, not text heuristics.
Receipts expose request_id, submitted_sql, executed_sql and default_limit_applied.

If the harness does not expose the MCP, use dev's existing QuackAPI endpoint:

```bash
curl --silent --show-error http://localhost:9495/sql \
  --data-urlencode 'sql=SELECT current_database() AS database_name;'
```

For a saved program, use --data-urlencode sql@/absolute/path/program.sql.
A local :memory: client with quack_query to quack:localhost:9494 is another
transport to the same service; see /duckstack:quack. Do not open the database file,
create another service or silently switch endpoints. Pass the endpoint to subagents.

## Explore and compose

- Issue live SELECTs first and iterate on useful result sets. A saved SQL file is
  an outcome of exploration, not a prerequisite. Reuse the source CTE, vary later
  CTEs, and use outer LIMIT 4 or LIMIT 7 while shaping columns. Save the verified,
  reusable program after it proves useful. Read-only exploration is cheap to
  reconstruct; uncertain writes still require receipt/state inspection before retry.
- SQL is the interactive workspace, not only a saved artifact format. ShellFS and
  self-dispatch make it an orchestrator for other runtimes. Generated Python inside
  SQL or separate files can be useful; choose from task needs and measured behavior.
- Turn verified discoveries into improvements to local skills and permitted memory
  notes: working extension examples, actual parameters, failure modes and simpler
  compositions. Fix contradictory advice. Preserve the user's intent, not just recipes.
- Probe the service and DESCRIBE relevant relations before selecting columns.
  Inspect its catalog on the service, not in an unrelated local database.
- Search agents.ext_catalog/ext_docs before runtime function introspection.
  Install and load needed community extensions yourself. Send LOAD separately
  before batches using extension PRAGMAs or parser syntax.
- Use typed SQL readers and read_lines selectors, retaining line numbers. Put
  globs in readers. Use HostFS for discovery and ShellFS for host commands through
  the selected service; measure sizes before reading contents.
- Literal/column-parameter binder errors call for per-row self-dispatch to the
  selected endpoint. Preserve source keys, statements, raw receipts and errors.
- Project scalars directly: SELECT 'widget' AS term, * FROM items. Do not cross
  join singleton settings CTEs or disguise them as comma joins or JOIN ON true.
  CROSS JOIN UNNEST(arr) is allowed. Other expansion needs a relational purpose;
  supported lateral readers must be correlated.
- Reuse same-query aliases, named CTEs, SELECT * EXCLUDE/REPLACE, GROUP BY ALL,
  GROUPING SETS, QUALIFY, DESCRIBE and SUMMARIZE. Prefer printf or Tera for SQL
  generation. No scalar subqueries in SELECT lists, COUNT(*), LIMIT 1, recursive
  CTEs or explicit AS MATERIALIZED. Prefer CTAS replacement and INSERT BY NAME.
- NULL is meaningful. Use nullif(col, '') when appropriate; never replace NULL
  with an empty string except at a final ML boundary that requires it.
- Keep base data and intermediate columns. Return bounded previews and IDs for
  drill-down. Exploration does not require saving every query; save the reusable
  pipeline once its shape is verified.

## Inspect the result

Check transport receipts and actual SQL results. HTTP 200 can carry an error.
Never replay an uncertain write; inspect state first. The MCP query/sql and
self_dispatch tools send JSON; 20 KB SQL bodies have been verified. The older
form-encoded path can reject approximately 8 KB. Keep large receipts as
individual rows rather than aggregating all response bodies. QuackAPI ed4552b
retains DuckDB diagnostics in HTTP errors; inspect both layers.

For authorization errors, inspect the actual route/tool and requested operation.
Port 9495 is dev's QuackAPI, not a presumed read-only database. Retain inner SQL
errors and fix them. Verify a small live result before scaling.
