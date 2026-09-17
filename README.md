# duckstack

InFrame-specific Claude skills for this machine's DuckDB stack.

These exist because agents get the **calling convention** wrong, not because they cannot write
SQL. The recurring failures are always the same two: treating the dev DuckDB as a file they can
open, and reaching for DuckLake without checking what is actually wired.

## Install

```bash
claude plugin marketplace add ~/duckstack
claude plugin install duckstack@duckstack
```

## Skills

| Skill | What it covers | Maturity |
|---|---|---|
| `duck` | The execution boundary and SQL process rules. Read first; every other skill assumes it. | verified |
| `ducklake` | Reaching a DuckLake catalog — and what is **not** wired (no secrets on dev). | **unexercised** |
| `agent-door` | What the `dev` MCP sidecar on 9496 can actually reach, incl. raw JSON-RPC. | verified |
| `crawl` | Fetching pages as tables, crawler × webbed, on the dev quack. | verified |
| `git-github` | Git history and GitHub as tables (`duck_tails`, `gh`). | verified |
| `superhuman-docs` | Superhuman Docs via the MCP connector or the `superhuman_docs` extension. | verified |

Maturity is not decoration. A skill marked **unexercised** documents a shape nobody has run
here; say so in your report rather than implying it works.

## The four doors, so nobody confuses them again

| Door | What it is | Who talks to it |
|---|---|---|
| `quack:localhost:9494` | dev DuckDB, read-write | humans, the main agent |
| `quack:localhost:9495` | dev DuckDB, read-only, `dev_gate` allows exactly one SELECT | agents |
| `http://localhost:9496/mcp` | the duckdb_mcp sidecar, registered as the `dev` MCP | agents with MCP only |
| `https://docs.superhuman.com/apis/mcp` | Superhuman Docs, a **remote** OAuth connector | Claude, for reading docs |

The fourth has nothing to do with the first three. Authorizing the Superhuman connector does
not give DuckDB anything, and the `superhuman_docs` extension cannot live behind the sidecar,
which sets `enable_external_access = false` one-way.

## Where the rest of the stack lives

Server config, the MCP gateway plists, telemetry and query artifacts are in the main repo at
`inframe/internal/duckdb/` — `setup.sql`, `service/`, `agent-gateway/`, `queries/`, `sources/`.
This repo is skills only.

## Relationship to duckdb-skills

The upstream-tracking fork is `asubbarao-ifr/duckdb-skills` (upstream `duckdb/duckdb-skills`).
It keeps the nine generic skills — `read-file`, `query`, `attach-db`, `s3-explore`, `spatial`,
`convert-file`, `duckdb-docs`, `read-memories`, `install-duckdb` — so `git merge upstream/main`
keeps working there. The InFrame-only skills live here.
