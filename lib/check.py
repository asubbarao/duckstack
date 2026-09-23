"""Prove the library on a real local DuckDB — no scheduler, no quack, no Postgres.

Nothing is stubbed: the Env is handed in. Bundles execute for real on Duck(); the pg_attach
path is rendered through a capturing Duck since it needs a Postgres to run.
"""

import tempfile
from pathlib import Path

from duckstack import Duck, DuckDBCreateTable, Env, render, resolve, run

lake = tempfile.mkdtemp(prefix="lake_")
env = Env(prod=False, lake=lake, pg_dsn="postgres://u:secret@host/db")

duck = Duck()
duck.execute("CREATE SCHEMA src")
duck.execute(
    "CREATE TABLE src.orders AS SELECT * FROM (VALUES (1, 'a', 10), (2, 'b', 20)) t(id, k, amt)"
)

print("=== 1. replace + to_lake: one bundle, one call, the tail is the receipt ===")
step = DuckDBCreateTable(
    name="orders_day", group="stg", to_lake=True, sql="SELECT * FROM src.orders"
)
bundle, receipt = run(step, "2026-09-22", duck, env)
print("  receipt:", receipt)
print("  rows:", duck.execute('SELECT dt, id, k, amt FROM stg."orders_day" ORDER BY id'))
print(
    "  lake files:", sorted(p.relative_to(lake).as_posix() for p in Path(lake).rglob("*.parquet"))
)

print()
print("=== 2. upsert: rerun the same partition after a source change — no key, no duplicate ===")
step = DuckDBCreateTable(
    name="orders_up", group="stg", mode="upsert", sql="SELECT * FROM src.orders"
)
run(step, "2026-09-22", duck, env)
duck.execute("UPDATE src.orders SET amt = 99 WHERE id = 2")
bundle, receipt = run(step, "2026-09-22", duck, env)
print("  receipt:", receipt)
print("  rows after 2nd run:", duck.execute('SELECT dt, id, amt FROM stg."orders_up" ORDER BY id'))

print()
print("=== 3. insert_or_replace with a declared key, and a fmt placeholder in the body ===")
step = DuckDBCreateTable(
    name="orders_keyed",
    group="stg",
    mode="insert_or_replace",
    schema="id INTEGER, k VARCHAR, amt INTEGER, PRIMARY KEY (dt, id)",
    sql="SELECT * FROM src.orders WHERE amt >= {floor}",
    fmt={"floor": "20"},
)
bundle, receipt = run(step, "2026-09-22", duck, env)
print("  rows:", duck.execute('SELECT dt, id, amt FROM stg."orders_keyed" ORDER BY id'))

print()
print("=== 4. pg_attach: rendered, DSN resolved at ship time and redacted in the log ===")


class Capture(Duck):
    def __init__(self) -> None:
        self.seen: list[str] = []

    def execute(self, bundle: str) -> list[object]:
        self.seen.append(bundle)
        return []


cap, logged = Capture(), []
step = DuckDBCreateTable(
    name="submission",
    group="lake",
    pg_attach=True,
    to_lake=True,
    sql="SELECT * FROM <TABLE:submission>",
)
run(step, "2026-09-22", cap, env, log=logged.append)
pg_stmt = next(s for s in cap.seen[0].split(";\n") if "$pg$" in s)
print("  shipped has the DSN:", env.pg_dsn in cap.seen[0])
print("  logged has the DSN:", env.pg_dsn in logged[0], "| has <pg_dsn>:", "<pg_dsn>" in logged[0])
print("  step statements carry no DSN:", not any(env.pg_dsn in s for s in step.statements))
print("  pg body:", pg_stmt.split("$pg$")[1])

print()
print("=== 5. resolve: <TABLE:x>, <DATEID>, {fmt}; prod flips the prefix ===")
for s in ["a < 3 AND b > 1", "DATE '<DATEID>' - 3", "<TABLE:foo>", "x <TABLE:bar> y", "{writer}"]:
    print(f"  {s!r:28} -> {resolve(s, '2026-09-22', True, None, env)!r}")
prod = resolve("<TABLE:foo>", "2026-09-22", True, None, Env(prod=True))
print(f"  {'<TABLE:foo>'!r:28} -> {prod!r}  (prod)")
try:
    resolve("<TABLE:oops", "2026-09-22")
except ValueError as e:
    print("  <TABLE:oops ->", e)
print("  render() == what run() ships:", render(step, "2026-09-22", env) == cap.seen[0])
