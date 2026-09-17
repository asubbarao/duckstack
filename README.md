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

| Skill | What it covers | Local maturity |
|---|---|---|
| `duck` | The execution boundary and SQL process rules. Read first; every other skill assumes it. | verified |
| `ducklake` | Attaching a DuckLake, snapshots and time travel. Local path verified; `s3://` blocked on credentials. | verified (local) |
| `agent-door` | What the `dev` MCP sidecar on 9496 can actually reach, incl. raw JSON-RPC. | verified |
| `crawl` | Fetching pages as tables, crawler × webbed, on the dev quack. | verified |
| `git-github` | Git history and GitHub as tables (`duck_tails`, `gh`). | verified |
| `duck-hunt` | CI job logs, test/build/lint output as tables (`duck_hunt`, `zipfs`, `gh run`). | verified |
| `superhuman-docs` | Superhuman Docs via the MCP connector or the `superhuman_docs` extension. | verified |

Maturity is not decoration. A skill marked **unexercised here** documents a shape nobody has
run on this machine; say so in your report rather than implying it works.

Before writing or trusting any of this, read `~/duckdb-flying/ext/<extension>.sql`. That
catalog carries a verified `-- @verified:` date per extension and is the source of truth;
these skills are summaries of it. `FROM find_sql('<question>')` searches it.

**Local maturity is not provenance.** They are different questions and must not be conflated.
`duckdb_extensions().installed_from` is the discriminator: `core` is DuckDB Labs' own work
(`ducklake`, `quack`, `httpfs`, `aws`), `community` is whatever someone published
(`crawler`, `webbed`). Adoption metrics — stars, weekly downloads — are the only signal
available for a community extension and say nothing useful about a first-party one. Never
rank a DuckDB Labs component against a community extension on download counts. DuckLake
being unexercised *here* would say nothing about DuckLake — and in fact it is exercised here:
`ext/ducklake.sql` has a working local catalog, snapshots and `AT (VERSION => n)`.

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
This repo is skills only, plus `references/` — reconciled per-extension API notes
(`duck_tails`, `duck_hunt`, `sitting_duck`, `gh`/`cloudfront`/`cloudwatch`) that the skills cite.

## Relationship to duckdb-skills

The upstream-tracking fork is `asubbarao-ifr/duckdb-skills` (upstream `duckdb/duckdb-skills`).
It keeps the nine generic skills — `read-file`, `query`, `attach-db`, `s3-explore`, `spatial`,
`convert-file`, `duckdb-docs`, `read-memories`, `install-duckdb` — so `git merge upstream/main`
keeps working there. The InFrame-only skills live here.
