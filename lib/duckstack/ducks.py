"""Where an operator runs. Duck is a local DuckDB and the default; Quack is the same over a quack
server. Either takes the whole rendered bundle in one call and returns its last statement's
rows — the receipt. run() walks dep_list first."""

import os
import secrets
from typing import Any

import duckdb

from duckstack.operators import LOCAL, Env, Operator, latest_ds, render


class Duck:
    """A local DuckDB. The default: nothing to install, nothing to serve. One connection, so
    a bundle's statements see each other."""

    def __init__(self, database: str = ":memory:") -> None:
        self.conn = duckdb.connect(database)

    def execute(self, bundle: str) -> list[Any]:
        """Run the whole bundle; the last statement's rows come back."""
        return self.conn.execute(bundle).fetchall()


class Quack(Duck):
    """The same over a quack server. The whole bundle goes in one quack_query, so the server
    holds the session state between statements and nothing is left on the client."""

    def __init__(
        self, uri: str = "quack:localhost:9494", token_file: str = "~/.duck/token"
    ) -> None:
        self.uri = uri
        self.token = open(os.path.expanduser(token_file)).read().strip()

    def execute(self, bundle: str) -> list[Any]:
        tag = f"$q{secrets.token_hex(4)}$"  # the bundle may hold $$ itself
        conn = duckdb.connect()
        try:
            conn.execute("LOAD quack")
            return conn.execute(
                f"SELECT * FROM quack_query('{self.uri}', {tag}{bundle}{tag}, "
                f"token := '{self.token}')"
            ).fetchall()
        finally:
            conn.close()


def run(
    op: Operator,
    ds: str,
    duck: Duck | None = None,
    env: Env = LOCAL,
    log: Any = None,
    done: set[int] | None = None,
) -> list[tuple[str, str, list[Any]]]:
    """Run an operator for one partition on one Duck, its dep_list first — each operator once,
    a failing wait stops everything downstream. Returns (name, bundle, receipt) per operator
    run, in the order they ran."""
    duck, done = duck or Duck(), set() if done is None else done
    ran = [r for dep in op.dep_list for r in run(dep, ds, duck, env, log, done)]
    if id(op) in done:
        return ran
    done.add(id(op))
    bundle = render(op, ds, env)
    pre = "" if env.prod else "test_"
    for table in latest_ds(bundle):  # only the database knows its newest partition
        [(latest,)] = duck.execute(
            "SELECT list_last(list_sort(array_agg(DISTINCT ds))) "
            f'FROM {op.namespace}."{pre}{table}"'
        )
        if latest is None:
            raise LookupError(f"<LATEST_DS:{table}>: {table} has no partitions")
        bundle = bundle.replace(f"<LATEST_DS:{table}>", str(latest))
    if "://" not in env.lake:  # COPY ... PARTITION_BY creates one level, never the lake root
        os.makedirs(os.path.expanduser(env.lake), exist_ok=True)
    if log:  # before shipping, so a failing bundle is on record — minus the DSN's password
        log(bundle.replace(env.pg_dsn, "<pg_dsn>") if env.pg_dsn else bundle)
    return [*ran, (op.name, bundle, duck.execute(bundle))]
