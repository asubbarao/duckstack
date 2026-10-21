"""Each case in hook_cases.json goes through the hook's own facts and checks; hook_cases.sql returns the verdict."""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
# The cases run on the duckdb found on PATH (HOOK_DUCKDB overrides), like the hook itself; a missing binary fails.
HOOK_DUCKDB = os.environ.get("HOOK_DUCKDB", "duckdb")
CASES = json.loads((ROOT / "tests/hook_cases.json").read_text())


@pytest.fixture(scope="module")
def results():
    duckdb = shutil.which(HOOK_DUCKDB)
    if duckdb is None:
        pytest.fail(
            f"no DuckDB CLI: {HOOK_DUCKDB!r} is not on PATH; install duckdb or set HOOK_DUCKDB"
        )
    run = subprocess.run(
        [duckdb, ":memory:", "-bail", "-f", "tests/hook_cases.sql"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=300,
        check=False,
    )
    assert run.returncode == 0, run.stderr
    return {row["case_id"]: row for row in json.loads(run.stdout)}


@pytest.mark.parametrize("case_id", [case["case_id"] for case in CASES])
def test_case(results, case_id):
    row = results[case_id]
    assert row["fires_ok"] and row["quiet_ok"], row
