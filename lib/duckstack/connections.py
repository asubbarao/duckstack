"""Connection declarations and the small executor contract used by factories."""

from __future__ import annotations

import json
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal, Protocol
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import duckdb


class Executor(Protocol):
    def execute(self, sql: str) -> list[tuple[Any, ...]]: ...


@dataclass
class ConnectToDatabase:
    """Lazy connection: constructing a pipeline never connects to a database.

    A local declaration retains its connection, including an in-memory database.
    Remote transports submit one complete bundle; they never split its statements.
    """

    db: str = ":memory:"
    type: Literal["local", "quack", "quackapi", "postgres"] = "local"
    token_file: str = "~/.duck/token"
    timeout: float = 60
    _local: Any = field(default=None, init=False, repr=False)

    def execute(self, sql: str) -> list[tuple[Any, ...]]:
        if self.type == "local":
            if self._local is None:
                self._local = duckdb.connect(self.db)
            try:
                return list(self._local.execute(sql).fetchall())
            except Exception:
                with suppress(duckdb.Error):
                    self._local.execute("ROLLBACK")
                raise
        if self.type == "quack":
            token = Path(self.token_file).expanduser().read_text().strip()
            conn = duckdb.connect()
            try:
                conn.execute("LOAD quack")
                return list(
                    conn.execute(
                        "SELECT * FROM quack_query(?, ?, token := ?)",
                        [self.db, sql, token],
                    ).fetchall()
                )
            finally:
                conn.close()
        if self.type == "quackapi":
            request = Request(
                self.db.rstrip("/") + "/sql",
                data=json.dumps({"sql": sql}).encode(),
                headers={"Content-Type": "application/json"},
            )
            try:
                with urlopen(request, timeout=self.timeout) as response:
                    rows = json.load(response)
            except HTTPError as exc:
                detail = exc.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"QuackAPI HTTP {exc.code}: {detail}") from exc
            if not isinstance(rows, list):
                raise RuntimeError(f"QuackAPI did not return rows: {rows!r}")
            return [tuple(row.values()) for row in rows]
        if self.type == "postgres":
            try:
                import psycopg
            except ImportError as exc:
                raise ImportError("Install duckstack[postgres] for PostgreSQL") from exc
            with psycopg.connect(self.db) as pg_conn, pg_conn.cursor() as cursor:
                cursor.execute(sql, prepare=False)
                result: list[tuple[Any, ...]] = []
                while True:
                    if cursor.description is not None:
                        result = list(cursor.fetchall())
                    if not cursor.nextset():
                        break
                return result
        raise ValueError(f"Unsupported connection type: {self.type}")

    def close(self) -> None:
        if self._local is not None:
            self._local.close()
            self._local = None
