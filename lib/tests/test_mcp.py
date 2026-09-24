"""The real duckstack-mcp entrypoint over stdio: it lists its tools, and render_step returns
the resolved bundle without the DSN."""

import json
import subprocess
from pathlib import Path
from typing import Any


def test_mcp_tools_over_stdio(tmp_path: Path) -> None:
    p = subprocess.Popen(
        ["uv", "run", "--quiet", "duckstack-mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert p.stdin and p.stdout

    def call(msg: dict[str, Any]) -> Any:
        p.stdin.write(json.dumps({"jsonrpc": "2.0", **msg}) + "\n")  # type: ignore[union-attr]
        p.stdin.flush()  # type: ignore[union-attr]
        return json.loads(p.stdout.readline()) if "id" in msg else None  # type: ignore[union-attr]

    try:
        call(
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            }
        )
        call({"method": "notifications/initialized"})
        tools = call({"id": 2, "method": "tools/list", "params": {}})
        assert {t["name"] for t in tools["result"]["tools"]} == {"render_step", "run_step"}
        out = call(
            {
                "id": 3,
                "method": "tools/call",
                "params": {
                    "name": "render_step",
                    "arguments": {
                        "name": "orders_day",
                        "sql": "SELECT * FROM <TABLE:orders>",
                        "ds": "2026-09-22",
                        "to_lake": True,
                        "pg_attach": True,
                        "lake": "/tmp/lake",
                        "pg_dsn": "postgres://u:secret@h/db",
                    },
                },
            }
        )
        text = out["result"]["content"][0]["text"]
        assert "ATTACH IF NOT EXISTS '<pg_dsn>' AS pg_orders_day" in text
        assert "secret" not in text
        assert '$pg$SELECT * FROM "orders"$pg$' in text  # pg source: no test_ prefix
        assert "DATE '2026-09-22'" in text
        assert "TO '/tmp/lake/orders_day'" in text
        ran = call(
            {
                "id": 4,
                "method": "tools/call",
                "params": {
                    "name": "run_step",
                    "arguments": {
                        "name": "t",
                        "sql": "SELECT 1 AS a, 2 AS b",
                        "ds": "2026-09-22",
                        "group": "mart",
                        "mode": "insert",
                        "to_lake": True,
                        "lake": str(tmp_path),
                    },
                },
            }
        )
        result = json.loads(ran["result"]["content"][0]["text"])
        assert 'INSERT INTO mart."t" BY NAME' in result["bundle"]
        assert result["receipt"] == [["mart", "t", 1, 3]]
        assert [p.name for p in tmp_path.rglob("*.parquet")] == ["part0.parquet"]
    finally:
        p.stdin.close()
        p.wait(timeout=10)
