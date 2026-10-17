-- Renders check_hits.sql: one UNION ALL branch per check, each the check's predicate_sql over toolcall_facts.
COPY (
  WITH branches AS (
    SELECT check_id,
           printf($t$SELECT '%s' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((%s), false)$t$,
                  check_id, predicate_sql) AS branch
    FROM hook_checks WHERE predicate_sql IS NOT NULL)
  SELECT printf(E'CREATE OR REPLACE VIEW check_hits AS\nWITH facts AS (FROM toolcall_facts)\n%s;',
                string_agg(branch, E'\nUNION ALL\n' ORDER BY check_id))
  FROM branches
) TO 'check_hits.sql' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x1f');
