# raw/ — source material, not product

Everything gathered by ADR-002 from ~/duckstack, ~/duckdb-skills, the duckdb-flying shelf and
quackpad lives here unchanged. None of it is loaded by the plugin and none of it is trusted.

A file leaves raw/ only by being rewritten: every claim re-run on this machine and dated,
every rule stated once, nothing carried over because it was already written. When a rewrite
lands in skills/ or shelf/, its raw/ sources are deleted in the same commit.

## What is in here (2026-09-17)

| raw/… | From |
|---|---|
| `skills/`, `references/`, `HOUSE.md` | `~/duckdb-skills` working tree + `~/duckstack` main, first gathering |
| `duckstack-skills-branch/` | `~/duckstack` branch `alok/duckstack-skills` (8167a06): skills authored instead of copied — `quack`, `ducklake`, references |
| `shelf/` | `~/personal` branch `alok/duckdb-flying-ext-catalog` (83dd348); `ext/quackapi_selfdispatch.from-quackpad.sql` from quackpad `pad-app` |
| `reviews/agent-stream/` | `~/reviews/agent-stream` `review/2026-09-17`: declarative_ls + declarative_pipeline through quackapi |
| `reviews/duckdb-llm-waves/` | `~/reviews/duckdb-llm-waves` `review/2026-09-17`: no shell files, self-dispatch through quackapi |
| `codex-archive/` | `~/.local/share/codex-archives/instal-2026-09-17-checkpoint` (c7866c8): slack/linear ingestion SQL, tera templates |
| `duckdb-skills-dirty/` | uncommitted edits in `~/duckdb-skills` as of this commit |

InFrame material (server, sources, queries, substrate) is in inframe branch
`aloksubbarao/inf-1321-duckstack-consolidated`, not here. Quackpad and the pad are in quackpad
branch `pad-app`.
