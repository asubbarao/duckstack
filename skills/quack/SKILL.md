---
name: quack
description: >
  How to actually call the Quack server. Quack owns the database file; you are an ephemeral
  client that sends complete SQL bodies to it. Use before any statement that touches dev,
  when a DuckDB CLI reports a lock error, when a table "does not exist" through an attach,
  or when reaching for .read / SET VARIABLE to sequence work.
argument-hint: "[probe | send <sql>]"
allowed-tools: Bash
---

Agents fail here in one specific way: they treat Quack as a database file they can open and
drive with CLI conveniences. It is a server that owns the file. Everything below was probed on
this machine on 2026-09-17 (DuckDB 1.5.5 osx_arm64, quack `c154811`); where a fact came from
reading rather than running, it says so.

## 1. The contract

**Quack is the sole owner of its database file.** Do not attach it, open it, or point a CLI at
it from anywhere else — not from a sidecar, not from a client writer, not with `-readonly`. A
lock error is not the server misbehaving; it is the caller being in the wrong place. Go through
the server.

**Send complete, idempotent SQL bodies.** Do not use `.read`, `SET VARIABLE` or `getvariable()`
as orchestration. Those are CLI session conveniences; they do not exist for the server, they do
not survive a reconnect, and a body that depends on them is not re-runnable. Every statement
you send should stand alone and produce the same result run twice.

**One statement is the unit of work.** Its inputs are files and environment; its output is a
table on the server or a stream. Not a pile of intermediate tables a later query is expected to
find lying around.

## 2. What actually works, and what silently does not

| From an ephemeral client | Result |
|---|---|
| `FROM dev.query($$SELECT …$$)` | runs **on the server**; joins, aggregates and table functions all fine |
| `SELECT … FROM dev.one_table` | works — a streaming scan through the attach |
| `SELECT … FROM dev.a JOIN dev.b` | **fails** — "Multiple streaming scans … not currently supported". Push the join inside `dev.query` |
| `FROM duckdb_tables() WHERE database_name='dev'` | **0 rows.** The remote catalog is not mirrored. Ask the server: `dev.query($$FROM duckdb_tables()$$)` |
| `dev.query($$SET memory_limit='8GiB'$$)` | refused — `Cannot change configuration option "memory_limit" - the configuration has been locked` |
| `dev.query($$LOAD <installed ext>$$)` | **succeeds.** `lock_configuration` locks settings, not extension loading |
| `ATTACH 'quack://host:port'` | silently not dispatched to the extension. Spell it `quack:host:port` |

Two of these are the ones that waste an afternoon.

**The catalog is not mirrored.** An agent lists tables, sees nothing, and concludes the table
was never created. It was; you asked the wrong process.

**`LOAD` is not blocked but it is not free either.** A `LOAD` against the server is *session
state on a shared server*: it changes the running server for every other client until launchd
restarts it, and it does not survive that restart. Do not load something into a shared server
as a side effect of exploring. If a body needs an extension, the server's own setup owns that
decision.

## 3. Resource ceilings are not symmetric

The server and your client have different limits, and a plan sized for one will not fit the
other.

| | memory_limit | threads |
|---|---|---|
| the server | `24.0 GiB` | `10` |
| an ephemeral client | `4.0 GiB` | `4` |

The client floor comes from `~/.duckdbrc`, which also carries the temp directory and the
per-process query/metrics/HTTP capture. **Never start a client with `-init`** — that *replaces*
the rc file rather than adding to it, and the process then runs unbounded and untelemetered.
This is the single most damaging flag on this machine.

That asymmetry is another reason to push work inside `dev.query($$…$$)` rather than streaming
rows out to sort or join them locally.

## 4. Credentials

The token is never a literal in SQL and is never printed. Read it with a reader, put it in a
variable for exactly as long as the `CREATE SECRET` takes, then reset it. Do not `trim()` it:
`trim` strips spaces, and a trailing newline survives.

A secret's `SCOPE` is a literal prefix match on the URI spelling, so it must match the
`quack:host:port` form character for character.

**The server currently holds no secrets at all** — `dev.query($$FROM duckdb_secrets()$$)`
returns zero rows. Anything reaching for `s3://` will therefore fail at the first *data* read,
not at `ATTACH`, which makes a credentials gap look like a bug in whatever you attached.

## 5. When it breaks

- **Lock error on the database file** → you are opening the file. Attach the server instead.
- **"Table does not exist" through the attach** → you asked the client's catalog. Ask the server.
- **"Multiple streaming scans"** → your join is client-side. Move it inside `dev.query`.
- **"Authorization failed" on a write** → you are on the read-only listener, whose gate refuses
  anything the parser does not see as exactly one SELECT. That is working as designed.
- **After a launchd restart** → `DETACH` then `ATTACH` again, and anything `LOAD`ed into the
  server's session is gone.

## 6. Report

Say which statements ran **on the server** versus in your client, and name any server state you
changed — a `LOAD`, a created table, a dropped one. A shared server means those are not private.
