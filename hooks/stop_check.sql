-- Stop hook: the wrapper puts the event's transcript_path in $STOP_TRANSCRIPT, and shellfs's shell expands it
-- inside the reader's literal path (stdin under -f did not parse multi-line NDJSON). Blocks the stop when the
-- final turn's text carries a "use Python / the stdlib instead of DuckDB" claim and the session never logged an
-- agent-log row with type 'verification' (both versions run on the same inputs, agent-dispatch section 3).
-- The settings.json wrapper skips it when stop_hook_active is true, so it forces at most one continuation.
LOAD shellfs;
LOAD tera;
.output /dev/null
-- The phrases that mark a reply as weighing DuckDB against Python; extend by adding a row.
CREATE OR REPLACE VIEW claim_terms AS
SELECT unnest(['stdlib', 'standard library', 'fromisoformat', 'plain python', 'lines of python', 'python instead',
               'replace duckdb', 'drop duckdb', 'remove duckdb', 'instead of duckdb', 'without duckdb', 'new dependency']) AS term;
CREATE OR REPLACE VIEW transcript AS
SELECT idx, json ->> 'type' AS line_type, json -> 'message' -> 'content' AS content
FROM read_json_objects('cat "$STOP_TRANSCRIPT" |', format := 'newline_delimited') WITH ORDINALITY AS t(json, idx);
CREATE OR REPLACE VIEW blocks AS
SELECT idx, line_type, unnest(CASE json_type(content) WHEN 'ARRAY' THEN content::JSON[] ELSE [content] END) AS block
FROM transcript WHERE line_type IN ('user', 'assistant');
CREATE OR REPLACE VIEW block_fields AS
SELECT idx, line_type, coalesce(block ->> 'type', 'text') AS block_type, lower(coalesce(block ->> 'text', block ->> '$')) AS text,
       (block -> 'input')::VARCHAR AS input
FROM blocks;
CREATE OR REPLACE VIEW last_prompt AS
SELECT max(idx) AS idx FROM block_fields
WHERE line_type = 'user' AND block_type = 'text' AND NOT starts_with(ltrim(text), '<');
CREATE OR REPLACE VIEW final_turn_blocks AS
SELECT b.idx, b.text, contains(b.text, 'duckdb') AS names_duckdb
FROM block_fields b JOIN last_prompt p ON b.idx > p.idx
WHERE b.line_type = 'assistant' AND b.block_type = 'text';
CREATE OR REPLACE VIEW term_hits AS
SELECT f.idx, t.term FROM final_turn_blocks f JOIN claim_terms t ON contains(f.text, t.term);
CREATE OR REPLACE VIEW verification_calls AS
SELECT idx FROM block_fields WHERE block_type = 'tool_use' AND contains(input, $v$'verification' AS type$v$);
CREATE OR REPLACE VIEW claim AS
SELECT array_agg(DISTINCT term ORDER BY term) AS terms FROM term_hits;
.output stdout
.mode list
.headers off
SELECT json_object('decision', 'block', 'reason', tera_render(
       $t$stop_check: this reply weighs DuckDB against Python/stdlib ({{ terms | join(sep=", ") }}) and this session has no agent-log row with type 'verification'. Run both in one agent-log COPY, the DuckDB side as SQL UNION ALL BY NAME the Python side as a shellfs uv run python reader, with type 'verification' (agent-dispatch section 3), or drop the claim and say it was not run.$t$,
       json_object('terms', terms), autoescape := false)) AS hook_output
FROM claim
WHERE len(terms) > 0 AND EXISTS (FROM final_turn_blocks WHERE names_duckdb) AND NOT EXISTS (FROM verification_calls);
