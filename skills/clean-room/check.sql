-- Clean-room proof for declared portable recipes.
-- Run from the repository root with: duckdb -c '.read skills/clean-room/check.sql'
-- The generated child command deliberately receives only HOME, PATH, and GITHUB_TOKEN (when set).

INSTALL hostfs FROM community;
LOAD hostfs;
INSTALL shellfs FROM community;
LOAD shellfs;
INSTALL read_lines FROM community;
LOAD read_lines;
INSTALL http_client FROM community;
LOAD http_client;
INSTALL quackapi FROM community;
LOAD quackapi;

-- Self-dispatch target: each source recipe row generates one complete SQL statement, and the
-- scalar http_post carries that statement to this same DuckDB process for execution.
CREATE OR REPLACE ROUTE clean_room_query POST '/_clean-room-query' AS
SELECT * FROM query($q);

SELECT * FROM quackapi_serve(19587, host := '127.0.0.1', access_log := false, enable_logging := false);

CREATE OR REPLACE TEMP TABLE clean_room_results AS
WITH hostfs_ls AS (
    SELECT file_name(path) AS skill, absolute_path(path) AS skill_path
    FROM ls('skills')
    WHERE is_dir(path) AND NOT starts_with(file_name(path), '.')
), declared AS (
    SELECT * FROM (VALUES ('clean-room', 'recipe.sql')) AS t(skill, recipe_file)
), recipe_files AS (
    SELECT d.skill, absolute_path(p.path) AS recipe_path
    FROM declared d
    JOIN hostfs_ls h ON h.skill = d.skill
    JOIN lsr('skills') p
      ON starts_with(absolute_path(p.path), h.skill_path || '/')
     AND file_name(p.path) = d.recipe_file
     AND starts_with(file_name(p.path), 'recipe')
     AND file_extension(p.path) = '.sql'
     AND is_file(p.path)
), command_text AS (
    SELECT skill, recipe_path,
           printf($cmd$
tmp_home=$(/usr/bin/mktemp -d); tmp_out=$(/usr/bin/mktemp); tmp_err=$(/usr/bin/mktemp); tmp_out_clean=$(/usr/bin/mktemp); tmp_err_clean=$(/usr/bin/mktemp);
trap '/bin/rm -rf "$tmp_home" "$tmp_out" "$tmp_err" "$tmp_out_clean" "$tmp_err_clean" "$tmp_out_clean.norm" "$tmp_err_clean.norm"' EXIT;
started=$(/bin/date +%%s);
if [ -n "${GITHUB_TOKEN:-}" ]; then
  /usr/bin/env -i HOME="$tmp_home" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin GITHUB_TOKEN="$GITHUB_TOKEN" duckdb :memory: -c ".read %s" >"$tmp_out" 2>"$tmp_err";
else
  /usr/bin/env -i HOME="$tmp_home" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin duckdb :memory: -c ".read %s" >"$tmp_out" 2>"$tmp_err";
fi;
exit_code=$?;
duration=$(( $(/bin/date +%%s) - started ));
/usr/bin/sed -n '1,40p' "$tmp_out" >"$tmp_out_clean";
/usr/bin/tr '\n\t\r' '   ' <"$tmp_out_clean" >"$tmp_out_clean.norm";
/usr/bin/sed -n '1,20p' "$tmp_err" >"$tmp_err_clean";
/usr/bin/tr '\n\t\r' '   ' <"$tmp_err_clean" >"$tmp_err_clean.norm";
stdout_head=$(/usr/bin/cut -c 1-4000 "$tmp_out_clean.norm");
stderr_head=$(/usr/bin/cut -c 1-4000 "$tmp_err_clean.norm");
passed=false; if [ "$exit_code" -eq 0 ]; then passed=true; fi;
printf '%%s\037%%s\037%%s\037%%s\037%%s\037%%s\n' '%s' "$exit_code" "$passed" "$stdout_head" "$stderr_head" "$duration"
           $cmd$, chr(39) || replace(recipe_path, chr(39), chr(39) || chr(39)) || chr(39),
           chr(39) || replace(recipe_path, chr(39), chr(39) || chr(39)) || chr(39),
           replace(skill, chr(39), chr(39) || chr(39))) AS shell_command
    FROM recipe_files
), exec_requests AS (
    SELECT skill, recipe_path,
           printf($sql$
SELECT %s AS skill, %s AS recipe_path,
       content AS receipt_line
FROM read_lines(%s)
           $sql$,
           chr(39) || replace(skill, chr(39), chr(39) || chr(39)) || chr(39),
           chr(39) || replace(recipe_path, chr(39), chr(39) || chr(39)) || chr(39),
           chr(39) || replace(shell_command || ' |', chr(39), chr(39) || chr(39)) || chr(39)) AS statement
    FROM command_text
), exec_receipts AS (
    SELECT skill, recipe_path, statement,
           http_post('http://127.0.0.1:19587/_clean-room-query',
                     MAP {'Content-Type': 'application/json'}, json_object('q', statement)) AS receipt
    FROM exec_requests
), execution_ok AS (
    SELECT e.entry.skill, 'execution' AS check_kind, e.entry.recipe_path,
           try_cast(split_part(e.entry.receipt_line, chr(31), 2) AS INTEGER) AS exit_code,
           split_part(e.entry.receipt_line, chr(31), 3) = 'true'
             AND try_cast(split_part(e.entry.receipt_line, chr(31), 2) AS INTEGER) = 0 AS passed,
           split_part(e.entry.receipt_line, chr(31), 4) AS stdout_head,
           split_part(e.entry.receipt_line, chr(31), 5) AS stderr_head,
           try_cast(split_part(e.entry.receipt_line, chr(31), 6) AS BIGINT) AS duration_seconds,
           []::VARCHAR[] AS banned_tokens,
           try_cast(r.receipt ->> '$.status' AS INTEGER) AS dispatch_status,
           r.receipt AS raw_receipt
    FROM exec_receipts r
    CROSS JOIN UNNEST(from_json(
        CASE WHEN try_cast(r.receipt ->> '$.status' AS INTEGER) = 200 THEN r.receipt ->> '$.body' ELSE '[]' END,
        '[{"skill":"VARCHAR","recipe_path":"VARCHAR","receipt_line":"VARCHAR"}]')) AS e(entry)
), execution_failed AS (
    SELECT skill, 'execution' AS check_kind, recipe_path,
           NULL::INTEGER AS exit_code, false AS passed, '' AS stdout_head,
           'dispatch failed: ' || coalesce(receipt ->> '$.body', receipt::VARCHAR) AS stderr_head,
           NULL::BIGINT AS duration_seconds, []::VARCHAR[] AS banned_tokens,
           try_cast(receipt ->> '$.status' AS INTEGER) AS dispatch_status,
           receipt AS raw_receipt
    FROM exec_receipts
    WHERE coalesce(try_cast(receipt ->> '$.status' AS INTEGER), -1) <> 200
), static_requests AS (
    SELECT skill, recipe_path,
           printf($sql$
SELECT %s AS skill, %s AS recipe_path, content AS sql_text
FROM read_text(%s)
           $sql$,
           chr(39) || replace(skill, chr(39), chr(39) || chr(39)) || chr(39),
           chr(39) || replace(recipe_path, chr(39), chr(39) || chr(39)) || chr(39),
           chr(39) || replace(recipe_path, chr(39), chr(39) || chr(39)) || chr(39)) AS statement
    FROM recipe_files
), static_receipts AS (
    SELECT skill, recipe_path, statement,
           http_post('http://127.0.0.1:19587/_clean-room-query',
                     MAP {'Content-Type': 'application/json'}, json_object('q', statement)) AS receipt
    FROM static_requests
), static_text AS (
    SELECT e.entry.skill, e.entry.recipe_path, e.entry.sql_text,
           try_cast(r.receipt ->> '$.status' AS INTEGER) AS dispatch_status,
           r.receipt AS raw_receipt
    FROM static_receipts r
    CROSS JOIN UNNEST(from_json(
        CASE WHEN try_cast(r.receipt ->> '$.status' AS INTEGER) = 200 THEN r.receipt ->> '$.body' ELSE '[]' END,
        '[{"skill":"VARCHAR","recipe_path":"VARCHAR","sql_text":"VARCHAR"}]')) AS e(entry)
), banned_tokens AS (
    SELECT * FROM (VALUES
        ('localhost:949'), ('/Users/'), ('~/.duck'), ('uv '), ('uvx'), ('python')
    ) AS t(token)
), static_matches AS (
    SELECT s.skill, s.recipe_path, s.dispatch_status, s.raw_receipt,
           b.token, contains(lower(s.sql_text), lower(b.token)) AS matched
    FROM static_text s
    CROSS JOIN banned_tokens b
), static_rows AS (
    SELECT skill, 'static' AS check_kind, recipe_path,
           NULL::INTEGER AS exit_code, NOT bool_or(matched) AS passed,
           '' AS stdout_head,
           CASE WHEN bool_or(matched)
                THEN 'banned tokens: ' || array_to_string(array_agg(token ORDER BY token) FILTER (WHERE matched), ', ')
                ELSE '' END AS stderr_head,
           0::BIGINT AS duration_seconds,
           array_agg(token ORDER BY token) FILTER (WHERE matched) AS banned_tokens,
           max(dispatch_status) AS dispatch_status,
           max(raw_receipt) AS raw_receipt
    FROM static_matches
    GROUP BY skill, recipe_path
), all_rows AS (
    SELECT * FROM execution_ok
    UNION ALL BY NAME
    SELECT * FROM execution_failed
    UNION ALL BY NAME
    SELECT * FROM static_rows
)
SELECT * FROM all_rows;

SELECT * FROM clean_room_results ORDER BY skill, check_kind;
SELECT * FROM quackapi_stop(19587);
SELECT CASE WHEN bool_and(passed) THEN 'clean-room: all checks passed'
            ELSE error('clean-room: at least one execution or static check failed') END AS result
FROM clean_room_results;
