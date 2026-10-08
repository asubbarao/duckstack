# Staging replica DuckDB

A long-running DuckDB that keeps a copy of the local Postgres clone of staging (`host=/tmp port=5432
dbname=staging_extensions_20260929`, 127 base tables), set up as the future graph back end for the business profile.
Modelled on dev (`../setup.sql`), sharing nothing with it. Nothing here writes to Postgres.

| file | role |
|---|---|
| `setup.sql` | the whole system (<50 lines): extensions, settings, `pull_log`, quack + quackapi, two crons, config lock |
| `pull.sql` | one pull tick; cron posts its current text to `/sql` every 10 s, so edits are live with no restart |
| `reads.sql` | graph views + `/org/live` and `/org/replica`; cron posts it every minute (routes bind when created) |
| `com.inframe.replica.plist` | launchd: token from `~/.duck/token`, stdin held open by a FIFO, KeepAlive |

Database `~/.duck/replica/staging_replica.duckdb` (disposable); logs `~/.duck/replica/server.{out,err}`.
Ports: **quack 9510** (`quack_query`), **quackapi 9511** (`POST /sql`, `/org/live`, `/org/replica`, `GET /health`).
## Start / stop
    launchctl bootstrap gui/$(id -u) ~/duckdb-skills/server/replica/com.inframe.replica.plist   # start (not at login)
    launchctl bootout   gui/$(id -u)/com.inframe.replica                                        # stop
    launchctl kickstart -k gui/$(id -u)/com.inframe.replica                                     # restart
Rebuild from nothing: stop, delete the `.duckdb` file, start; the first cycle (~3 min) refills every table.
Query: `FROM quack_query('quack:localhost:9510', $$...$$, token := getenv('QUACK_TOKEN'))`, or POST `{"sql": ...}` to `:9511/sql`.
## The pull
`pull.sql` attaches Postgres `READ_ONLY` (`ATTACH IF NOT EXISTS`, so a source that was down comes back) and clears
the attach's catalog cache. Source tables come from Postgres `information_schema` (BASE TABLE; the attach's
`duckdb_tables()` also lists the 6 views). A table is due 5 min after its last ok copy, 30 s after a failure, or at
once if never copied; each tick takes the 8 most overdue. The pending set is derived from `pull_log`, never tracked.
Each due table becomes one generated body (mark start in a temp table; `CREATE OR REPLACE TABLE public.t AS FROM
pg.public.t`; return start, finish, rows), posted with `quackapi_post` to this process's `/sql`. The receipts are
`array_agg`'d, UNNESTed, and inserted `BY NAME` into `pull_log`, together with the statement, the HTTP status, the
error, the request id and the raw body. Replicated tables live in schema `public`, so the same query text runs
against `pg.public.x` (live) and `public.x` (copy).
Why these knobs (measured): http_client's `http_post` returns status -1 at 10 s and a cold audit_log copy takes
20-29 s (warm: ~2 s). One unbounded fan-out of 133 posts overran the quack door and 110 failed; the prior limit of 8
still produced transport refusals, so a tick now copies at most 4 tables, matching the replica's 4 DuckDB workers.
Those land as error rows and are retried 30 s later. cronjob runs a job serially, so ticks never overlap.
## Full copy vs incremental
This is a **full re-copy**: correct for inserts, updates, hard deletes and schema changes, and simple, but every
table is read in full every 5 minutes (audit_log is 2.3M rows / 557 MB). Incremental would need, per table: a
primary key on the DuckDB side (all 127 have one in Postgres; CTAS drops it), a change column to watermark on
(72 tables have `updated_at`, 40 only `created_at`, 15 neither, audit_log among them), an overlap window because
commit order is not timestamp order, and `INSERT OR REPLACE ... BY NAME` upserts. Hard deletes are invisible to a
watermark, so it also needs a periodic primary-key anti-join, or logical decoding (a publication and slot:
`wal_level=logical`, which is `replica` here; on RDS that means a parameter-group change and the replication role).
## Live vs replicated reads
`POST :9511/org/live {"org": "<uuid>"}` answers from Postgres through the attach at request time.
`/org/replica` runs the same text on the copy. Use **live** when the answer must reflect the last second (a write
the user just made) or is a narrow lookup Postgres can serve from an index. Use the **replica** for graph walks,
wide scans, and anything that should not load the source; it can be up to ~5 minutes stale (`pull_log` says how
stale per table), and it keeps answering when the source is down.
## Graph
`duckpgq` is not published for DuckDB 1.5.5 (community repo: HTTP 404), so the graph is `graph.node` (organization,
project, compliance_group, compliance_group_member, network_company) and `graph.edge` (PARENT_OF, HAS_PROJECT,
HAS_COMPLIANCE_GROUP, HAS_MEMBER, IS_COMPANY, HAS_NETWORK_COMPANY); a hop is a join of `graph.edge` on `dst = src`.
## Pointing at a deployed database later
Change only the ATTACH in `pull.sql`: a DuckDB postgres secret for the host and credentials, and a login role that
holds SELECT and nothing else (db-connect's `inframe_readonly`), over the SSM tunnel. Keep `READ_ONLY`; never CDC by
triggers or any other write to the source. The replica file is as confidential as the source.
