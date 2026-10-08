-- Clean-room recipe status on the existing QuackAPI. LOAD quackapi, hostfs, shellfs,
-- read_lines and http_client before this file.
-- The route mirrors skills/clean-room/check.sql for the repository's declared recipe list.
CREATE OR REPLACE ROUTE skills_check GET '/skills/check' AS
WITH run AS (
    SELECT split_part(content, chr(31), 1) AS skill,
           split_part(content, chr(31), 2)::INTEGER AS exit_code,
           split_part(content, chr(31), 3) = 'true' AS passed,
           split_part(content, chr(31), 4) AS stdout_head,
           split_part(content, chr(31), 5) AS stderr_head,
           split_part(content, chr(31), 6)::BIGINT AS duration_seconds
    FROM read_lines($cmd$
tmp_home=$(/usr/bin/mktemp -d); tmp_out=$(/usr/bin/mktemp); tmp_err=$(/usr/bin/mktemp); tmp_out_clean=$(/usr/bin/mktemp); tmp_err_clean=$(/usr/bin/mktemp);
trap '/bin/rm -rf "$tmp_home" "$tmp_out" "$tmp_err" "$tmp_out_clean" "$tmp_err_clean" "$tmp_out_clean.norm" "$tmp_err_clean.norm"' EXIT;
started=$(/bin/date +%s);
if [ -n "${GITHUB_TOKEN:-}" ]; then
  /usr/bin/env -i HOME="$tmp_home" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin GITHUB_TOKEN="$GITHUB_TOKEN" duckdb :memory: -c ".read skills/clean-room/recipe.sql" >"$tmp_out" 2>"$tmp_err";
else
  /usr/bin/env -i HOME="$tmp_home" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin duckdb :memory: -c ".read skills/clean-room/recipe.sql" >"$tmp_out" 2>"$tmp_err";
fi;
exit_code=$?;
duration=$(( $(/bin/date +%s) - started ));
/usr/bin/sed -n '1,40p' "$tmp_out" >"$tmp_out_clean";
/usr/bin/tr '\n\t\r' '   ' <"$tmp_out_clean" >"$tmp_out_clean.norm";
/usr/bin/sed -n '1,20p' "$tmp_err" >"$tmp_err_clean";
/usr/bin/tr '\n\t\r' '   ' <"$tmp_err_clean" >"$tmp_err_clean.norm";
stdout_head=$(/usr/bin/cut -c 1-4000 "$tmp_out_clean.norm");
stderr_head=$(/usr/bin/cut -c 1-4000 "$tmp_err_clean.norm");
passed=false; if [ "$exit_code" -eq 0 ]; then passed=true; fi;
printf '%s\037%s\037%s\037%s\037%s\037%s\n' 'clean-room' "$exit_code" "$passed" "$stdout_head" "$stderr_head" "$duration"
    $cmd$ || ' |')
), static_text AS (
    SELECT content AS sql_text FROM read_text('skills/clean-room/recipe.sql')
), banned_tokens AS (
    SELECT * FROM (VALUES
        ('localhost:949'), ('/Users/'), ('~/.duck'), ('uv '), ('uvx'), ('python')
    ) AS t(token)
), static AS (
    SELECT NOT bool_or(contains(lower(sql_text), lower(token))) AS passed,
           array_agg(token ORDER BY token) FILTER (WHERE contains(lower(sql_text), lower(token))) AS banned_tokens
    FROM static_text CROSS JOIN banned_tokens
)
SELECT skill, 'execution' AS check_kind, exit_code, passed, stdout_head, stderr_head,
       duration_seconds, []::VARCHAR[] AS banned_tokens
FROM run
UNION ALL BY NAME
SELECT 'clean-room' AS skill, 'static' AS check_kind, NULL::INTEGER AS exit_code,
       static.passed AS passed, '' AS stdout_head,
       CASE WHEN static.passed THEN '' ELSE 'banned tokens: ' || array_to_string(static.banned_tokens, ', ') END AS stderr_head,
       0::BIGINT AS duration_seconds, static.banned_tokens AS banned_tokens
FROM static;
