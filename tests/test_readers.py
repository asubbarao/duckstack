"""Execute the shared SQL against real readers, with only gh acquisition replaced."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = {
    "github_run.sql": ROOT / "skills/ci-timing/references/github_run.sql",
    "github_jobs.sql": ROOT / "skills/ci-timing/references/github_jobs.sql",
}


@pytest.fixture(scope="module")
def environment(tmp_path_factory):
    home = tmp_path_factory.mktemp("reader-home")
    env = dict(os.environ, HOME=str(home))
    env.pop("DUCKDB_EXTENSION_DIRECTORY", None)
    assert not (home / ".duckdb").exists()
    return env


def execute(example, environment, **parameters):
    executable = shutil.which("duckdb")
    assert executable, "Use the documented uv command to supply duckdb-cli"
    return subprocess.run(
        [executable, ":memory:", "-bail", "-json", "-f", str(EXAMPLES[example])],
        cwd=ROOT,
        env=dict(environment, **parameters),
        text=True,
        capture_output=True,
        timeout=180,
        check=False,
    )


@pytest.fixture
def github(tmp_path, environment):
    # This executable supplies acquisition fixtures only; the SQL/readers are unmodified.
    command = tmp_path / "gh"
    command.write_text(
        f"#!{sys.executable}\n"
        "import os, pathlib, sys\n"
        "assert sys.argv[1] == 'api'\n"
        "pathlib.Path(os.environ['GH_ARGUMENTS']).write_text(' '.join(sys.argv[1:]))\n"
        "sys.stdout.write(pathlib.Path(os.environ['GH_FIXTURE']).read_text())\n"
        "sys.exit(int(os.environ.get('GH_EXIT', '0')))\n"
    )
    command.chmod(0o755)
    fixture = tmp_path / "payload.json"
    arguments = tmp_path / "arguments.txt"
    return (
        fixture,
        arguments,
        dict(
            environment,
            PATH=str(tmp_path) + os.pathsep + environment["PATH"],
            GH_FIXTURE=str(fixture),
            GH_ARGUMENTS=str(arguments),
            CI_REPO="owner/repo",
            CI_RUN_ID="42",
        ),
    )


def test_run_retains_nested_and_unknown_fields(github):
    fixture, arguments, env = github
    payload = {
        "id": 42,
        "status": "in_progress",
        "actor": {"login": "alice"},
        "future_field": [1, 2],
    }
    fixture.write_text(json.dumps(payload))
    result = execute("github_run.sql", env)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == [payload]
    assert arguments.read_text() == "api repos/owner/repo/actions/runs/42"


def test_jobs_preserves_pages_nested_steps_and_running_jobs(github):
    fixture, arguments, env = github
    jobs = [
        {
            "id": 1,
            "run_id": 42,
            "status": "completed",
            "conclusion": "success",
            "steps": [{"number": 1, "name": "test"}],
        },
        {
            "id": 2,
            "run_id": 42,
            "status": "in_progress",
            "conclusion": None,
            "steps": [],
        },
    ]
    pages = [{"total_count": 2, "jobs": jobs[:1]}, {"total_count": 2, "jobs": jobs[1:]}]
    fixture.write_text(json.dumps(pages))
    result = execute("github_jobs.sql", env)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == pages
    assert (
        arguments.read_text()
        == "api repos/owner/repo/actions/runs/42/jobs?per_page=100 --paginate --slurp"
    )


@pytest.mark.parametrize("example", ["github_run.sql", "github_jobs.sql"])
@pytest.mark.parametrize(
    "payload", ["", "not json", '{"message":"Not Found","status":"404"}']
)
def test_acquisition_errors_fail_instead_of_becoming_evidence(github, example, payload):
    fixture, _, env = github
    fixture.write_text(payload)
    result = execute(example, dict(env, GH_EXIT="1"))
    assert result.returncode != 0


def test_empty_jobs_retain_empty_page(github):
    fixture, _, env = github
    fixture.write_text('[{"total_count":0,"jobs":[]}]')
    result = execute("github_jobs.sql", env)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == [{"total_count": 0, "jobs": []}]


@pytest.mark.parametrize(
    "example,payload",
    [
        ("github_run.sql", '{"id":42,"status":"completed"}'),
        ("github_jobs.sql", '[{"total_count":0,"jobs":[]}]'),
    ],
)
def test_nonzero_command_exit_rejects_otherwise_valid_json(github, example, payload):
    fixture, _, env = github
    fixture.write_text(payload)
    result = execute(example, dict(env, GH_EXIT="1"))
    assert result.returncode != 0
    assert "exited abnormally" in result.stderr
