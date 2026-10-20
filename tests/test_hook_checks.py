"""Each case in hook_cases.json goes through the hook's own facts and checks; the named checks must fire or stay quiet."""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
# The PreToolUse hook runs on this binary with its ~/.duckdbrc extensions, so the cases do too.
HOOK_DUCKDB = os.environ.get("HOOK_DUCKDB", "/opt/homebrew/bin/duckdb")


@pytest.fixture(scope="module")
def results():
    if not shutil.which(HOOK_DUCKDB):
        pytest.skip(f"the hook's DuckDB ({HOOK_DUCKDB}) is not on this machine")
    run = subprocess.run(
        [HOOK_DUCKDB, ":memory:", "-bail", "-f", "tests/hook_cases.sql"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=300,
        check=False,
    )
    assert run.returncode == 0, run.stderr
    rows = json.loads(run.stdout[run.stdout.index("[{") :])
    return {row["case_id"]: row for row in rows}


CASES = json.loads((ROOT / "tests/hook_cases.json").read_text())


@pytest.mark.parametrize("case_id", [case["case_id"] for case in CASES])
def test_case(results, case_id):
    row = results[case_id]
    assert set(row["fires"]) <= set(row["fired"]), row
    assert not set(row["quiet"]) & set(row["fired"]), row
