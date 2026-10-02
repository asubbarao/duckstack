# Disposable agent DuckDBs

## Contract now

SQL source is the system. `server/setup.sql`, its included definition files, and the skills are
upstream; a running DuckDB, its catalog file, WAL, listeners and materialized runtime tables are
downstream products. Deleting `~/.duck/dev.duckdb` and its WAL must be recoverable by replaying the
source. Missing extensions are installed and loaded in that source, not reported as blockers.

Dev remains the convenient shared default. Editing a watched server definition intentionally kills
and rebuilds it. The editing agent tells concurrent agents that their requests died, verifies a new
instance identity and endpoints through the MCP `runtime` tool, and never retries an uncertain write.
There is no clean-state ceremony around this local runtime: source ownership and scoped Git promotion
protect concurrent work; the running database does not.

`skills/query-duckdb/own_server.sql` is the isolated profile. It starts a fresh `:memory:` DuckDB with
its own Quack, QuackAPI and MCP listeners. It discovers occupied TCP listeners with ShellFS, chooses
three candidates, and lets bind success decide. A PID is not a port, and an `lsof` snapshot cannot
reserve a port; a bind race causes a clean failed startup and retry.

## Next: composable profiles

Split bootstrap SQL into replayable layers:

1. core settings, extension installs and logging;
2. local SQL/Quack/MCP transports;
3. dev-only shared schedules and materializations;
4. optional agent identity and publication.

Then dev and every agent can run the same core profile with distinct identity, log path and
OS-assigned or probed ports. Replaying a profile must be idempotent. A process supervisor is useful
for availability, not authority; even a periodic full restart should preserve behavior.

## Later: MinIO/S3 and DuckLake

Each agent first owns its raw evidence and logs. Publish immutable, uniquely named Parquet or JSON
objects to MinIO/S3 with `httpfs`/`aws` (or `sshfs` only when the selected transport is actually SSH).
Each object records producer, instance, session/run, source time, schema version, checksum and source
keys. Upload is append-only: never let several agents rewrite one object, and never treat an API error
page as evidence.

DuckLake is the shared catalog layer after object publication is trustworthy. Multi-writer use needs
a transactional shared catalog such as Postgres plus MinIO/S3 for data files; do not share a local
`.duckdb` catalog among writers. Agents attach the same explicit catalog, append idempotently using
stable run/object identities, and retain raw object locations so another agent can resume or audit a
run. `DATA_INLINING_ROW_LIMIT 0` is required when even small inserts must land in object storage.

This yields the intended topology: Alok and each agent have an expendable local DuckDB and local
logs; MinIO/S3 is the immutable exchange; DuckLake provides shared relational state and snapshots.
Local/private material remains outside publication until explicitly selected.
