# Portable bootstrap

A server-free entrypoint: a fresh `duckdb :memory:` CLI connection with the CI reader
extensions loaded, and the same connection as a stdio MCP server. It does not use the
dev DuckDB in `server/setup.sql`. These entrypoints target macOS and Linux; CI exercises Linux.

Check prerequisites before running the entrypoint:

```bash
uv --version && git --version
# Only for queries that acquire GitHub data:
gh --version && gh auth status
```

Install missing commands with your platform's package manager. On macOS with Homebrew:

```bash
brew install uv git gh
```

The CLI package is `duckdb-cli`, distinct from the Python `duckdb` package. The commands
below let `uv` provision the pinned CLI; a global `duckdb` installation is not required.
Community extensions are installed by `setup.sql` on first use, so it needs network
access and a writable extension cache. Version checks establish command availability;
the smoke tests below establish that the actual entrypoints work.

From the repository root, start a fresh CLI connection with the required extensions:

```bash
uvx --from duckdb-cli==1.5.5 duckdb :memory: -bail \
  -c ".read server/portable/setup.sql" \
  -c "SELECT getvariable('repo') AS repo;"
```

`setup.sql` installs and loads the reader extensions and records the repository root in a
connection-local variable. It can be read again in the same connection. It does not fetch
GitHub history or build analysis tables. Python callers can use the same SQL statements in
a DuckDB connection; CLI `.read` is a client command.

For a stdio MCP client, launch from the repository root:

```bash
claude mcp add duckstack -- uvx --from duckdb-cli==1.5.5 duckdb -bail \
  -c ".read server/portable/mcp.sql"
```

This exposes one `query_sql` tool for relational queries, including installed readers.
The built-in query tool rejects filesystem readers, so this explicitly trusted-local
adapter binds SQL as the argument of `query()`; it does not launch a nested CLI or
rewrite quoting. SQL result output is suppressed on the protocol channel.
Use this only with a trusted local client: SQL and ShellFS can read files and execute
host commands with the server process's permissions. This is not a sandbox.

The bootstrap tests run the documented CLI and MCP entrypoints with an empty extension
cache and verify reader results, repeat loading, failure propagation and a real MCP call:

```bash
uv run --no-project --with pytest --with mcp --with duckdb-cli==1.5.5 \
  python -m pytest tests/test_bootstrap.py -q
```
