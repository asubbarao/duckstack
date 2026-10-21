"""Exercise the dev MCP and /sql routes, including their real Quack transport. Every tool runs its SQL unchanged.

Run with DUCKSTACK_DEV_URL=http://127.0.0.1:9495. Server-bootstrap CI supplies its own server.
"""

import asyncio
import json
import os
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

BASE = os.environ.get("DUCKSTACK_DEV_URL", "").rstrip("/")
pytestmark = pytest.mark.skipif(
    not BASE, reason="requires a running Duckstack dev service"
)


def post(path, payload):
    request = Request(
        BASE + path, json.dumps(payload).encode(), {"Content-Type": "application/json"}
    )
    try:
        with urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except HTTPError as error:
        return error.code, json.load(error)


def rpc(method, **params):
    status, response = post(
        "/mcp/", {"jsonrpc": "2.0", "id": 7, "method": method, "params": params}
    )
    assert status == 200, response
    assert response["id"] == 7
    return response["result"]


def call(name, sql):
    argument = "statement" if name == "execute" else "sql"
    result = rpc("tools/call", name=name, arguments={argument: sql})
    assert result["isError"] is False, result
    text = result["content"][0]["text"]
    return json.loads(text), text


def preview(sql):
    result, text = call("query", sql)
    assert len(text.encode("utf-8")) <= 8192
    assert result["row_limit"] == 50
    assert result["byte_limit"] == 8192
    assert result["returned_rows"] == len(result["rows"])
    assert result["truncated"] is (result["returned_rows"] < result["total_rows"])
    return result


def test_tools_advertise_any_sql_and_the_reply_cap():
    tools = {tool["name"]: tool for tool in rpc("tools/list")["tools"]}
    assert set(tools) == {"query", "query_full", "execute"}
    assert "total_rows" in tools["query"]["description"]
    assert "row_limit" in tools["query"]["description"]
    assert tools["execute"]["inputSchema"]["required"] == ["statement"]
    assert tools["query"]["inputSchema"]["properties"] == {"sql": {"type": "string"}}
    for tool in tools.values():
        assert "any SQL" in tool["description"]
        assert "one SELECT" not in tool["description"]


def test_official_mcp_client_lists_and_calls_every_tool():
    # Field names follow mcp 2.x (input_schema, is_error); server-bootstrap pins the version.
    pytest.importorskip("mcp")
    from mcp import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    async def session_replies():
        async with streamable_http_client(BASE + "/mcp/") as streams:
            read, write, *_ = streams
            async with ClientSession(read, write) as session:
                await session.initialize()
                listed = await session.list_tools()
                calls = {}
                for tool in listed.tools:
                    (argument,) = tool.input_schema["required"]
                    calls[tool.name] = await session.call_tool(
                        tool.name, {argument: "SELECT 42 AS n"}
                    )
                return calls

    calls = asyncio.run(session_replies())
    assert set(calls) == {"query", "query_full", "execute"}
    assert not any(reply.is_error for reply in calls.values())
    texts = {name: json.loads(reply.content[0].text) for name, reply in calls.items()}
    assert (
        texts["query"]["rows"] == texts["query_full"] == texts["execute"] == [{"n": 42}]
    )


@pytest.mark.parametrize("size", [0, 1, 49, 50, 51, 200])
def test_preview_preserves_order_and_reports_exact_boundary(size):
    result = preview(
        f"SELECT * FROM range({size}) ORDER BY range DESC; -- keep this comment"
    )
    assert result["rows"] == [{"range": i} for i in reversed(range(size))][:50]
    assert result["total_rows"] == size
    assert result["truncated"] is (size > 50)
    assert result["reason"] == ("row_limit" if size > 50 else None)


def test_large_result_is_cut_to_the_row_limit_with_its_total():
    result = preview("SELECT * FROM range(100000)")
    assert result["returned_rows"] == 50
    assert result["total_rows"] == 100000
    assert result["reason"] == "row_limit"


@pytest.mark.parametrize(
    "sql,rows",
    [
        (
            "PIVOT (SELECT range AS v, chr(120 + (range % 2)::INT) AS k FROM range(4)) ON k USING sum(v)",
            [{"x": 2, "y": 4}],
        ),
        ("LOAD json", []),
        ("LOAD json; SELECT 2 AS b", [{"b": 2}]),
        ("SELECT 1 AS a;\n-- a trailing comment", [{"a": 1}]),
    ],
)
def test_query_runs_any_sql_unchanged(sql, rows):
    status, raw = post("/sql", {"sql": sql})
    assert status == 200, raw
    result = preview(sql)
    assert result["rows"] == raw == rows
    assert result["total_rows"] == len(rows)
    assert result["truncated"] is False


@pytest.mark.parametrize("name", ["query", "execute"])
def test_ddl_runs_through_the_mcp(tmp_path, name):
    db = tmp_path / f"{name}.duckdb"
    sql = (
        f"ATTACH '{db}' AS mcp_ddl_{name}; CREATE OR REPLACE TABLE mcp_ddl_{name}.t AS SELECT 42 AS n; "
        f"SELECT n FROM mcp_ddl_{name}.t; DETACH mcp_ddl_{name}"
    )
    result, _ = call(name, sql)
    assert (result["rows"] if name == "query" else result) == [{"n": 42}]
    assert db.exists()


def test_inner_sql_limit_is_preserved():
    result = preview("SELECT * FROM range(200) ORDER BY range DESC LIMIT 7")
    assert result["rows"] == [{"range": i} for i in range(199, 192, -1)]
    assert result["truncated"] is False


@pytest.mark.parametrize(
    "value", ["repeat('x', 1000)", "repeat('é🦆', 500)", r"repeat(E'\\n\\t\\\\', 400)"]
)
def test_byte_limit_preserves_whole_rows_and_utf8(value):
    result = preview(
        f"SELECT range AS idx, {value} AS value FROM range(30) ORDER BY range"
    )
    assert 0 < result["returned_rows"] < 30
    assert result["reason"] == "byte_limit"
    assert result["truncated"] is True
    assert [row["idx"] for row in result["rows"]] == list(
        range(result["returned_rows"])
    )
    assert all(row["value"] == result["rows"][0]["value"] for row in result["rows"])


def test_oversized_first_row_is_not_reported_as_empty_complete_result():
    result = preview("SELECT repeat('🦆', 9000) AS huge")
    assert result["rows"] == []
    assert result["returned_rows"] == 0
    assert result["total_rows"] == 1
    assert result["truncated"] is True
    assert result["reason"] == "oversized_row"


def test_preview_stops_at_first_overflow_instead_of_skipping_a_row():
    result = preview(
        "SELECT range AS idx, CASE WHEN range=1 THEN repeat('x', 9000) ELSE 'small' END AS value FROM range(3) ORDER BY range"
    )
    assert result["rows"] == [{"idx": 0, "value": "small"}]
    assert result["reason"] == "byte_limit"
    assert result["truncated"] is True


def test_preview_rows_are_the_sql_reply_rows():
    sql = "SELECT 42 AS n, NULL AS missing, true AS flag, [1,2] AS items, json_object('x',1) AS nested, 'O''Brien' AS name"
    result = preview(sql)
    full, _ = call("query_full", sql)
    status, raw = post("/sql", {"sql": sql})
    assert status == 200, raw
    assert result["rows"] == full == raw
    assert raw[0]["items"] == [1, 2]
    assert raw[0]["name"] == "O'Brien"


def test_query_full_and_sql_have_no_preview_row_limit():
    sql = "SELECT * FROM range(1200) ORDER BY range DESC"
    full, _ = call("query_full", sql)
    status, raw = post("/sql", {"sql": sql})
    assert status == 200
    expected = [{"range": i} for i in reversed(range(1200))]
    assert full == raw == expected


def test_query_full_has_no_preview_byte_limit():
    full, text = call("query_full", "SELECT repeat('🦆', 9000) AS huge")
    assert len(text.encode("utf-8")) > 8192
    assert full == [{"huge": "🦆" * 9000}]


@pytest.mark.parametrize("via", ["execute", "sql"])
def test_copy_writes_all_rows_and_returns_complete_receipt(tmp_path, via):
    path = tmp_path / f"{via}.parquet"
    sql = f"COPY (SELECT * FROM range(1200)) TO '{path}' (FORMAT PARQUET)"
    if via == "execute":
        receipt, _ = call("execute", sql)
    else:
        status, receipt = post("/sql", {"sql": sql})
        assert status == 200, receipt
    assert receipt == [{"Count": 1200}]
    actual, _ = call(
        "query_full", f"SELECT count(range) AS n FROM read_parquet('{path}')"
    )
    assert actual == [{"n": 1200}]


@pytest.mark.parametrize("name", ["query", "query_full", "execute"])
@pytest.mark.parametrize(
    "sql", ["SELECT FROM", "SELECT * FROM duckstack_missing_preview_test"]
)
def test_sql_errors_stay_errors(name, sql):
    argument = "statement" if name == "execute" else "sql"
    result = rpc("tools/call", name=name, arguments={argument: sql})
    assert result["isError"] is True
    assert json.loads(result["content"][0]["text"])["detail"]


def test_preview_error_text_also_respects_byte_budget():
    result = rpc(
        "tools/call", name="query", arguments={"sql": "SELECT error(repeat('x',12000))"}
    )
    assert result["isError"] is True
    text = result["content"][0]["text"]
    assert len(text.encode("utf-8")) <= 8192
    diagnostic = json.loads(text)
    assert diagnostic["truncated"] is True
    assert diagnostic["reason"] == "byte_limit"
    assert diagnostic["detail"]


@pytest.mark.parametrize(
    "name,arguments",
    [
        ("unknown", {"sql": "SELECT 42"}),
        ("query", {}),
        ("query", {"sql": 42}),
        ("query_full", {"sql": None}),
        ("execute", {"sql": "SELECT 42"}),
    ],
)
def test_invalid_calls_are_not_executed(name, arguments):
    result = rpc("tools/call", name=name, arguments=arguments)
    assert result["isError"] is True
