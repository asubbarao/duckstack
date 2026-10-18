-- PreToolUse hook, one DuckDB invocation:  /opt/homebrew/bin/duckdb :memory: -f .../hooks/hook.sql   (event JSON on stdin)
-- Builds toolcall_facts for the one incoming call with the corpus definitions, evaluates every active check
-- (check_hits.sql is rendered from hook_checks by render_hits.sql), prints the hook decision JSON or nothing.
-- Read from ~/.duck/deploy, the checkout of main, so a merged rule applies to every agent within 30 s.
.output /dev/null
.read /Users/aloksubbarao/.duck/deploy/hooks/hook_sources.sql
.read /Users/aloksubbarao/.duck/deploy/hooks/toolcall_facts.sql
.read /Users/aloksubbarao/.duck/deploy/hooks/hook_checks.sql
.read /Users/aloksubbarao/.duck/deploy/hooks/check_hits.sql
.output stdout
.mode list
.headers off
WITH fired AS (
  SELECT c.check_id, c.hook_decision, concat_ws(': ', c.check_id, c.message) AS reason
  FROM check_hits h JOIN hook_checks c USING (check_id)
  WHERE c.action IN ('block', 'warn')),
verdict AS (
  SELECT list(hook_decision) AS decisions, string_agg(reason, ' | ' ORDER BY check_id) AS reasons FROM fired)
SELECT CASE WHEN list_contains(decisions, 'deny') THEN json_object('hookSpecificOutput', json_object(
              'hookEventName', 'PreToolUse', 'permissionDecision', 'deny', 'permissionDecisionReason', 'BLOCKED by hook_checks: ' || reasons))
            WHEN list_contains(decisions, 'ask') THEN json_object('hookSpecificOutput', json_object(
              'hookEventName', 'PreToolUse', 'permissionDecision', 'ask', 'permissionDecisionReason', 'hook_checks: ' || reasons))
            ELSE json_object('hookSpecificOutput', json_object('hookEventName', 'PreToolUse', 'additionalContext', 'hook_checks: ' || reasons)) END AS hook_output
FROM verdict WHERE reasons IS NOT NULL;
