-- Diagnostics; original experiments retained in archive/2026-09-29-original/.
INSTALL jev FROM community;
LOAD jev;
SELECT name, value FROM duckdb_settings()
WHERE starts_with(name, 'jev') AND name <> 'jev_api_key' ORDER BY name;
SELECT jev_stats() AS process_usage;
SELECT jev_prob(NULL, 'Does the text request money back?') AS missing_input;

-- Missing credentials/API failure is an error, never a false answer.
-- EXPLAIN binds; it does not establish provider success or model accuracy.
-- Bound input before inference; an outer LIMIT is not a model-call budget.
-- Keep IDs/truth outside payload. Preserve raw answers and unanswered rows.
-- Community jev and MotherDuck prompt_jev have different APIs.
-- Score position is not probability. Missing confidence belongs in review.
-- Original signed build caches across model/endpoint/key changes; upstream PR: judoaseeta/duckdb-jev#3.
