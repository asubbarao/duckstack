"""Run the published entrypoints without a user's DuckDB configuration or extension cache."""

import asyncio
import json
import os
from pathlib import Path
import shutil
import subprocess

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def clean_env(tmp_path_factory):
    home = tmp_path_factory.mktemp("duckdb-home")
    env = os.environ.copy()
    env["HOME"] = str(home)
    env.pop("DUCKDB_EXTENSION_DIRECTORY", None)
    assert not (home / ".duckdb").exists()
    return env


def cli(env, *statements):
    return subprocess.run(
        [
            shutil.which("duckdb"),
            ":memory:",
            "-bail",
            "-json",
            "-c",
            ".read server/portable/setup.sql",
            *[arg for statement in statements for arg in ("-c", statement)],
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )


def test_readers_and_repeat_loading(clean_env):
    result = cli(
        clean_env,
        ".read server/portable/setup.sql",
        "SELECT getvariable('repo') AS repo, * FROM read_csv("
        "$cmd$printf 'code,active\\n001,true\\n'|$cmd$, all_varchar := true)",
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == [
        {"repo": str(ROOT), "code": "001", "active": "true"}
    ]
    result = cli(
        clean_env,
        "SELECT * FROM read_json($cmd$printf '%s' '{\"id\":7,\"ok\":true}'|$cmd$)",
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == [{"id": 7, "ok": True}]


def test_cli_propagates_sql_errors(clean_env):
    result = cli(clean_env, "SELECT error('bootstrap-negative-control')")
    assert result.returncode != 0
    assert "bootstrap-negative-control" in result.stderr


def test_stdio_mcp_query(clean_env):
    async def run():
        server = StdioServerParameters(
            command=shutil.which("duckdb"),
            args=[":memory:", "-bail", "-c", ".read server/portable/mcp.sql"],
            cwd=str(ROOT),
            env=clean_env,
        )
        async with stdio_client(server) as (reader, writer):
            async with ClientSession(reader, writer) as session:
                await session.initialize()
                tools = await session.list_tools()
                assert [tool.name for tool in tools.tools] == ["query_sql"]
                tool = tools.tools[0]
                properties = tool.model_dump(by_alias=True)["inputSchema"]["properties"]
                sql_key = next(k for k in properties if k in ("query", "sql"))
                result = await session.call_tool(
                    tool.name, {sql_key: "SELECT 42 AS answer"}
                )
                assert not result.model_dump(by_alias=True).get("isError", False), (
                    result
                )
                assert json.loads(result.content[0].text) == [{"answer": 42}]
                result = await session.call_tool(
                    tool.name,
                    {
                        sql_key: "SELECT * FROM read_json($cmd$printf '%s' "
                        '\'{"id":7,"ok":true}\'|$cmd$)'
                    },
                )
                assert json.loads(result.content[0].text) == [{"id": 7, "ok": True}]
                # The server propagates SQL failures as JSON-RPC errors, not successful rows.
                with pytest.raises(Exception, match="SQL error:.*mcp-negative-control"):
                    await session.call_tool(
                        tool.name, {sql_key: "SELECT error('mcp-negative-control')"}
                    )

    asyncio.run(asyncio.wait_for(run(), timeout=180))
