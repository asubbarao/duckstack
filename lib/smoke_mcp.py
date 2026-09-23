"""Speak JSON-RPC to the real duckstack-mcp entrypoint over stdio: initialize, list the
tools, call render_step once, and confirm the DSN never reaches the output."""

import json
import subprocess
from typing import Any

p = subprocess.Popen(
    ["uv", "run", "--quiet", "duckstack-mcp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
assert p.stdin and p.stdout and p.stderr


def send(msg: dict[str, Any]) -> None:
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()


def recv() -> Any:
    line = p.stdout.readline()
    return json.loads(line) if line.strip() else None


send(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "smoke", "version": "0"},
        },
    }
)
init = recv()
print("initialize ->", init["result"]["serverInfo"] if init and "result" in init else init)
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
tl = recv()
print("tools ->", [t["name"] for t in tl["result"]["tools"]] if tl and "result" in tl else tl)
send(
    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "render_step",
            "arguments": {
                "name": "orders_day",
                "sql": "SELECT * FROM <TABLE:orders>",
                "ds": "2026-09-22",
                "group": "stg",
                "to_lake": True,
                "lake": "/tmp/lake",
                "pg_dsn": "postgres://u:secret@h/db",
            },
        },
    }
)
tc = recv()
if tc and "result" in tc:
    text = tc["result"]["content"][0]["text"]
    print("render_step ->")
    print("\n".join("   " + line for line in text.splitlines()))
    print("secret in output:", "secret" in text)
else:
    print("render_step ->", tc)
p.stdin.close()
p.wait(timeout=10)
err = p.stderr.read().strip()
print("stderr:", err[-400:] if err else "(none)")
