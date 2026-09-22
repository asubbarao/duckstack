# duckstack

Source-controlled DuckDB skill package for the planned **System Quack** runtime. It targets one
Mac-owned DuckDB process and its three shared interfaces: Quack on `127.0.0.1:9494`, QuackAPI on
`127.0.0.1:9495`, and user-wide native MCP `duckdb` on `127.0.0.1:9496/mcp`.

This package does not deploy the runtime. Its endpoint, extension, and tool descriptions are the
intended contract and must be discovered and verified against the live service after deployment.
Never infer acceptance from these files, a port, or an installed cache.

## System Quack contract

- The ordinary agent entry point is `duckdb.quack_query(sql)`: one complete body, defaulting to
  writable `workspace`.
- Native MCP discovery (`tools/list`) and live `duckdb_extensions()` / `duckdb_functions()` are
  authoritative for tool schemas and SQL signatures.
- Routine reads, workspace writes, and extension `INSTALL`/`LOAD` are authorized. `main` and
  `public` changes require explicit task authorization; do not ask again within that authorized
  work.
- A connection failure is a failure of the selected service, not authorization to start a
  sidecar, attach a scratch database, recreate startup/telemetry state, or substitute an endpoint.
- ShellFS needs an explicit bounded pipeline. cronjob needs explicit scheduled SQL. Unknown
  write outcomes are inspected, never automatically replayed.

## Catalog

| Skill | Role |
|---|---|
| `duck` | System Quack boundary, discovery, extension, ShellFS, and cronjob rules |
| `agent-door` | native `duckdb` MCP discovery and planned 14-tool contract |
| `query` | complete workspace SQL bodies or explicitly selected local files |
| `quack` | native tool use and explicit Quack-protocol orchestration |
| `attach-db` | explicitly selected non-System-Quack files, URIs, and document databases |
| `self-dispatch` | relational fan-out through explicit QuackAPI, ShellFS, or Quack loops |
| `crawl`, `read-file`, `convert-file`, `s3-explore`, `spatial` | source-specific data access |
| `ducklake`, `markdown`, `yaml`, `parser_tools`, `pdf` | extension-specific SQL workflows |
| `duck-tails`, `git-github`, `duck-hunt` | repository, GitHub, and CI data as relations |
| `install-duckdb` | native MCP extension installation/loading and verification |
| `dispatch-claude` | explicit-only Codex override for local Claude CLI delegation |

## Source package refresh

After a source release/version update, refresh consumers rather than editing installed cache files:

```bash
claude plugin marketplace update duckstack
claude plugin update duckstack@duckstack
codex plugin marketplace upgrade
codex plugin remove duckstack@duckstack
codex plugin add duckstack@duckstack
```

If either client reports an unchanged cached version, remove and install the package again through
that client's normal plugin commands. Do not modify user configuration or installed plugin caches
from this source repository. Point the user-wide MCP registration itself at
`http://127.0.0.1:9496/mcp` under the name `duckdb`; this repository only carries the matching
project manifest.
