---
name: superhuman-docs
description: >
  Read a Superhuman Docs document through its MCP connector or DuckDB extension, then land
  bounded relational results in System Quack when explicitly requested.
argument-hint: "<document URL or id> [--land table]"
---

There are two independent routes:

| Need | Route |
|---|---|
| read page prose and tables through connected OAuth | Superhuman Docs MCP connector |
| query document tables through DuckDB | `superhuman_docs` extension with an approved token |

For System Quack landing, use native `duckdb.quack_query(sql)`, defaulting to `workspace`. First
discover native tools and inspect live extension/function signatures. If `superhuman_docs` is
needed in System Quack, install/load it through MCP, inspect actual `duckdb_functions()` fields,
and make a bounded invocation. Do not recreate old setup/sidecar configuration or copy a secret
into source-controlled SQL.

An extension document `ATTACH` is document-specific and belongs in the selected SQL process; it
is not an attachment of System Quack itself. Ask for an approved secret source, avoid printing its
value, preserve source URL/ID and raw returned fields, and land only an explicitly requested,
idempotent workspace relation. Changes to `main`/`public` still require task authorization.
