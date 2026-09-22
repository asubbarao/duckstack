---
name: dispatch-claude
description: >
  Explicit-only Codex override for temporarily routing bounded subagent work to the logged-in
  local Claude Code CLI. Use only when the user explicitly invokes $dispatch-claude or requests
  Claude subagents.
---

# Dispatch Claude (Codex only)

Normal delegation remains native Codex: use Luna for routine bounded work, Terra for substantive
implementation or investigation, and Sol for review. Do not activate Claude from a generic
request to delegate, use agents, or work in parallel. This skill changes only the delegation
route; Codex remains responsible for scope, approvals, integration, testing, and delivery.

## Explicit activation and control record

Activate only when the user invokes `/dispatch-claude`, `$dispatch-claude`, or explicitly asks to
use Claude subagents. Obtain the current Codex thread ID from the enclosing session metadata. If
the thread ID is unavailable, stop and ask for it; never invent a global or shell-derived ID.

Create/read the control record through native `duckdb.quack_query`, not through a shell helper or
local state file. The service selects `workspace` before this body runs:

```sql
CREATE TABLE IF NOT EXISTS codex_claude_dispatch_control (
    thread_id VARCHAR PRIMARY KEY,
    active BOOLEAN NOT NULL,
    activated_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

INSERT INTO codex_claude_dispatch_control AS control
    (thread_id, active, activated_at, expires_at)
VALUES ($thread$<current-codex-thread-id>$thread$, true, current_timestamp, current_timestamp + INTERVAL 4 HOUR)
ON CONFLICT (thread_id) DO UPDATE SET
    active = excluded.active,
    activated_at = excluded.activated_at,
    expires_at = excluded.expires_at;

SELECT thread_id, active, expires_at
FROM codex_claude_dispatch_control
WHERE thread_id = $thread$<current-codex-thread-id>$thread$;
```

State the expiry once. Before every later Claude dispatch, read this control record through MCP:

```sql
SELECT active AND expires_at > current_timestamp AS active, expires_at
FROM codex_claude_dispatch_control
WHERE thread_id = $thread$<current-codex-thread-id>$thread$;
```

If it is absent, false, or expired, resume native Codex delegation. Never silently renew it. An
explicit activation renews it for four hours. To stop early, set `active = false` through the same
MCP tool. This workspace record is routine authorized work; do not use `main` or `public`.

## Dispatch while active

Use non-interactive Claude Code from the actual task repository:

```bash
claude -p --model <model> --effort <effort> \
  --output-format json --permission-mode <mode> < prompt.txt
```

- Preserve a user-requested Claude model. Otherwise use `sonnet` for routine bounded work and
  `opus` only for architecture, difficult debugging, or final review.
- Use `plan` for read-only work and `acceptEdits` only when the current task authorizes edits in
  that checkout. Never use dangerous permission bypasses or weaken filesystem/approval boundaries.
- Give each Claude job one bounded task with paths, scope, deliverable, validation, and explicit
  exclusions. Keep at most three jobs active and no more than three dispatch rounds without a new
  user request. Claude agents must not activate this skill or recursively dispatch Claude.
- Capture results in `/private/tmp`, then verify claims and changes in the parent Codex session.
  A Claude result is evidence, never completion.
