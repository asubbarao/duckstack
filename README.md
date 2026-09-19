# duckstack

Public fork of [duckdb/duckdb-skills](https://github.com/duckdb/duckdb-skills) retargeted at
the **duckstack**: one persistent DuckDB per machine held locked by a `quack` server, agents as
stateless `:memory:` clients, an MCP sidecar as the agent door, and this user's SQL process
rules. The style guide is the user's own repos (`asubbarao/duckdb-ops-toolkit` conduit,
`duckdb-chrome-bridge`, `claudes-console`), not upstream. Upstream stays mergeable —
`git fetch upstream && git merge upstream/main`.

| Skill | Status | What changed |
|---|---|---|
| `duck` | **new** | the record label: boundary, the three stateless client forms, the reference repos, SQL process rules, 1.5.5 gotchas |
| `attach-db` | rewritten | pick the door (`dev` / `dev-ro` / `quack:host:port` / Superhuman doc / a file no server holds), probe it, list its catalog, hand back the two-line head — **no state file** |
| `query` | rewritten | one statement via `-c`, anything longer is a single `.sql` artifact via `-f`; `--#` lines are the human's instructions; joins through `dev.query($$…$$)` |
| `crawl` | **new** | crawler × webbed with all 13 `crawl()` parameters, the capability ladder, the shape catalog, and `--chrome` (duckdb-chrome-bridge) for SPAs/auth |
| `agent-door` | **new** | what the 9496 MCP can reach (only `dev.query`), raw JSON-RPC, review of `mcp-setup.sql` against the duckdb_mcp docs |
| `git-github` | **new** | `duck_tails` + `gh` extension + `gh` CLI, as tables |
| `install-duckdb` | note added | client-side only; the server's extensions live in `setup.sql` |
| `read-file`, `convert-file`, `s3-explore`, `spatial`, `duckdb-docs`, `read-memories` | upstream | untouched; they run sandboxed `duckdb :memory:` clients |

There is deliberately **no `state.sql`, no `.read`, no `-init`**: the persistent state is the
server. Every statement carries `LOAD quack; ATTACH 'quack:localhost:9494' AS dev (TYPE quack,
TOKEN getenv('QUACK_TOKEN'));` and the token is exported on the shell line
(`QUACK_TOKEN="$(cat ~/.duck/token)"`). `-c`, `-f` and `-cmd` keep `~/.duckdbrc` (the resource
floor); `-init` replaces it (verified: 15 threads / 38 GiB, no telemetry).

Install from the local clone:

```
/plugin marketplace add ~/duckdb-skills
/plugin install duckstack@duckstack
```

Codex reads the same manifest: `codex plugin marketplace add ~/duckdb-skills && codex plugin add duckstack@duckstack`.
Both CLIs cache by version: after editing, `claude plugin uninstall duckstack@duckstack && claude plugin install duckstack@duckstack`
and `codex plugin add duckstack@duckstack` again, or bump the version.

---

# duckdb-skills (upstream README — its `state.sql` / `-init` mechanism is NOT used in this fork)

A [Claude Code](https://claude.ai/code) plugin that adds DuckDB-powered skills for data exploration and session memory.

## Installation

### From the Discover tab (coming soon)

We are working on submitting this plugin to the official Anthropic marketplace. Once listed, it will appear in the **Discover** tab when you run `/plugin` inside Claude Code.

### From GitHub (available now)

Add the repository as a plugin source and install:

```
/plugin marketplace add duckdb/duckdb-skills
```
```
/plugin install duckdb-skills@duckdb-skills
```

This registers the GitHub repo as a marketplace and installs the plugin. Skills will be available as `/duckstack:<skill-name>` in all future sessions.

### Updating

To pull the latest version, update the marketplace first and then the plugin:

```
/plugin marketplace update duckdb-skills
/plugin update duckdb-skills@duckdb-skills
```

## Skills

### `attach-db`
Attach a DuckDB database file for interactive querying. Explores the schema (tables, columns, row counts) and writes a SQL state file so all other skills can restore the session automatically. You can choose to store state in the project directory (`.duckdb-skills/state.sql`) or in your home directory (`~/.duckdb-skills/<project>/state.sql`).

```
/duckstack:attach-db my_analytics.duckdb
```

Supports multiple databases — running `attach-db` again can append to the existing state file.

### `query`
Run SQL queries against attached databases or ad-hoc against files. Accepts raw SQL or natural language questions. Uses DuckDB's Friendly SQL dialect. Automatically picks up session state from `attach-db`.

```
/duckstack:query FROM sales LIMIT 10
/duckstack:query "what are the top 5 customers by revenue?"
/duckstack:query FROM 'exports.csv' WHERE amount > 100
```

### `read-file`
Read and explore any data file — CSV, JSON, Parquet, Avro, Excel, spatial, SQLite, Jupyter notebooks, and more — locally or from remote storage (S3, GCS, Azure, HTTPS). Auto-detects the format by file extension using a built-in `read_any` table macro. Suggests `query` for further exploration.

```
/duckstack:read-file variants.parquet what columns does it have?
/duckstack:read-file s3://my-bucket/data.parquet describe the schema
/duckstack:read-file https://example.com/data.csv how many rows?
```

### `duckdb-docs`
Search DuckDB and DuckLake documentation and blog posts using full-text search against the hosted search indexes. No local setup required — queries run over HTTPS by default, with an option to cache the index locally for faster offline searches.

```
/duckstack:duckdb-docs window functions
/duckstack:duckdb-docs "how do I read a CSV with custom delimiters?"
```

### `read-memories`
Search past Claude Code session logs to recover context from previous conversations — decisions made, patterns established, open TODOs. Offloads large result sets to a temporary DuckDB file for interactive drill-down.

```
/duckstack:read-memories duckdb --here
```

### `install-duckdb`
Install or update DuckDB extensions. Supports `name@repo` syntax for community extensions and a `--update` flag that also checks whether your DuckDB CLI is on the latest stable version.

```
/duckstack:install-duckdb spatial httpfs
/duckstack:install-duckdb gcs@community
/duckstack:install-duckdb --update
```

## Session state

All skills share a single `state.sql` file per project — a plain SQL file containing ATTACH/USE/LOAD statements, secrets, and macros. When state is first needed, you'll be asked where to store it:

1. **In the project directory** (`.duckdb-skills/state.sql`) — colocated with the project, optionally gitignored
2. **In your home directory** (`~/.duckdb-skills/<project>/state.sql`) — keeps the repo clean

The file is append-only and idempotent. Any skill restores the session via `duckdb -init state.sql`.

## Local development

To test skills locally from a clone of this repo:

```bash
# 1. Clone the repo
git clone https://github.com/duckdb/duckdb-skills.git
cd duckdb-skills

# 2. Launch Claude Code with the local plugin directory
claude --plugin-dir .
```

This loads the plugin from disk instead of the marketplace, so any edits to `skills/*/SKILL.md` take effect immediately — just start a new conversation (or re-run the slash command) to pick up changes.

You can test individual skills directly:

```
/duckstack:read-file some_local_file.parquet
/duckstack:duckdb-docs pivot unpivot
/duckstack:query SELECT 42
```

**Prerequisites:** DuckDB CLI must be installed. If it isn't, the skills will offer to install it via `/duckstack:install-duckdb`.

## How the skills work together

Skills reference each other where it makes sense:

- `read-file` suggests `query` for follow-up exploration and `attach-db` for persisting large files
- `query`, `read-file`, and `read-memories` all use `duckdb-docs` to troubleshoot DuckDB errors automatically
- All skills share the same `state.sql` — secrets and macros set up by `read-file` are reused by `query`, and databases attached by `attach-db` are available everywhere

## Platform support

These skills have been tested on **macOS** and **Linux**. Windows is not yet fully supported — some shell commands and path handling may not work as expected. We plan to improve Windows compatibility in a future release.

## Reporting issues & suggestions

Found a bug or have an idea for improvement? Open an issue at:

**https://github.com/duckdb/duckdb-skills/issues**

For DuckDB-specific bugs (extension loading, SQL errors), please include the DuckDB version (`duckdb --version`) and the full error message.
