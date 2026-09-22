-- Run this complete artifact through native duckdb.quack_query(sql).
-- The tool selects workspace before this body. Do not ATTACH System Quack, create state.sql,
-- or use a local token/startup helper. main/public mutations need explicit task authorization.
-- Use $body$...$body$ for nested SQL that itself contains $$.

-- Inspect runtime extensions/functions before using unfamiliar capabilities:
-- FROM duckdb_extensions() ORDER BY extension_name;
-- FROM duckdb_functions() WHERE function_name = '<function>';

-- Artifact body begins below.
