# Self-dispatch / agent SQL corpus (for Claude + swarm)

## Hostfs / declarative queries (the ones from 2026-09-12)
| File | What |
|------|------|
| `declarative_discover.sql` | Lazy lsr → prune dirs → typed ext → hostfs scalars (`is_file`, `file_size`, `file_last_modified`, `hsize`, …) |
| `declarative_pipeline.sql` | Multi-wave :memory: self-dispatch — discover → as-is readers → subsequent `read_lines` |
| `declarative_ls.sql` | Progressive ls/lsr waves |

## Catalog / signature
| File | What |
|------|------|
| `~/personal/agent-stream/query_catalog.sql` | Good-query catalog COPY templates |
| `~/personal/agent-stream/agent_signature.sql` | Agent signature pattern |
| `agent_signature.sql` (this folder) | Pointer |

## Magazine
`../magazine/01`–`06` persona takes.

## Rules
- Hostfs column names = function names (`is_dir`, `file_last_modified`, …)
- Reader TVF columns left as-is (no `col:0`); CASE only picks which reader
- `read_csv(..., auto_detect := true)` only
- Subsequent CTE self-dispatch runs `read_lines` on prior reader paths
- Prefer `:memory:` + local httpserver leaf; no nested outer+leaf on :9496
