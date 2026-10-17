-- Generated from wave 1's bash_ast/body_calls.sql (lines 15-388, its CTE chain unchanged) as a view over
-- the caller's src (Bash calls) and n (bash AST nodes) views, so the hook parses one call exactly as wave 1 parsed the corpus.
CREATE OR REPLACE VIEW bash_src AS
WITH
-- node text without the delimiters of quoted strings (the parser says which node is a quoted string)

tok AS (

  SELECT *, CASE type WHEN 'string' THEN substr(peek, 2, length(peek) - 2)

                      WHEN 'raw_string' THEN substr(peek, 2, length(peek) - 2)

                      WHEN 'ansi_c_string' THEN substr(peek, 3, length(peek) - 3)

                      ELSE peek END AS text

  FROM n),

-- flags that consume the next word (nvals 2: the next two words)

value_flags AS (

  SELECT unnest(exes) AS exe, unnest(flags) AS flag, nvals FROM (

    SELECT ['git'] AS exes, ['-C', '-c', '--git-dir', '--work-tree', '--namespace'] AS flags, 1 AS nvals

    UNION ALL SELECT ['gh'], ['-R', '--repo'], 1

    UNION ALL SELECT ['jq'], ['--arg', '--argjson', '--slurpfile', '--rawfile'], 2

    UNION ALL SELECT ['jq'], ['--indent', '-f', '--from-file', '-L'], 1

    UNION ALL SELECT ['curl'], ['-H', '--header', '-X', '--request', '-d', '--data', '--data-raw', '--data-binary', '--data-urlencode', '--json', '-o', '--output', '-u', '--user', '-A', '--user-agent', '-e', '--referer', '-m', '--max-time', '-w', '--write-out', '-F', '--form', '--connect-timeout', '-b', '--cookie', '-c', '--cookie-jar', '-T', '--upload-file', '--retry', '-K', '--config', '-x', '--proxy', '--cacert', '--cert', '--resolve', '--url'], 1

    UNION ALL SELECT ['duckdb'], ['-c', '-s', '-cmd', '-init', '-f', '-separator', '-nullvalue', '-newline'], 1

    UNION ALL SELECT ['sqlite3'], ['-cmd', '-init', '-separator'], 1

    UNION ALL SELECT ['psql'], ['-c', '--command', '-d', '--dbname', '-h', '--host', '-p', '--port', '-U', '--username', '-f', '--file', '-v', '--set', '-o', '-F', '-P'], 1

    UNION ALL SELECT ['python', 'python3', 'python3.10', 'python3.11', 'python3.12', 'python3.13', 'python3.14'], ['-c', '-m', '-W', '-X'], 1

    UNION ALL SELECT ['osascript'], ['-e', '-l'], 1

    UNION ALL SELECT ['node'], ['-e', '--eval', '-p', '--print', '-r', '--require'], 1

    UNION ALL SELECT ['bash', 'sh', 'zsh'], ['-c', '-o'], 1

    UNION ALL SELECT ['perl'], ['-e', '-E'], 1

    UNION ALL SELECT ['ruby'], ['-e'], 1

    UNION ALL SELECT ['sed', 'gsed'], ['-e', '-f', '-i'], 1

    UNION ALL SELECT ['awk', 'gawk'], ['-F', '-v', '-f'], 1

    UNION ALL SELECT ['grep', 'egrep', 'rg'], ['-e', '-f', '-A', '-B', '-C', '-m', '--max-count', '-g', '--glob', '-t', '--type'], 1

    UNION ALL SELECT ['head', 'tail'], ['-n', '-c'], 1

    UNION ALL SELECT ['timeout', 'gtimeout'], ['-s', '-k', '--signal', '--kill-after'], 1

    UNION ALL SELECT ['xargs'], ['-I', '-n', '-P', '-L', '-d', '-E'], 1

    UNION ALL SELECT ['uv'], ['--directory', '--project', '--with', '--python', '-p', '--package', '--env-file', '--group', '--extra'], 1

    UNION ALL SELECT ['npx', 'pnpm', 'npm'], ['-p', '--package', '-C', '--prefix', '--filter'], 1

    UNION ALL SELECT ['sudo'], ['-u', '-g'], 1

    UNION ALL SELECT ['nice'], ['-n'], 1

    UNION ALL SELECT ['podman', 'docker'], ['-e', '--env', '-v', '--volume', '-p', '--publish', '--name', '-w', '--workdir', '-u', '--user', '--network', '--entrypoint'], 1

    UNION ALL SELECT ['make'], ['-C', '-f', '-j'], 1)),

-- flags whose value is a program for that interpreter

prog_flags AS (

  SELECT unnest(exes) AS exe, unnest(flags) AS flag FROM (

    SELECT ['duckdb'] AS exes, ['-c', '-s', '-cmd'] AS flags

    UNION ALL SELECT ['sqlite3'], ['-cmd']

    UNION ALL SELECT ['psql'], ['-c', '--command']

    UNION ALL SELECT ['python', 'python3', 'python3.10', 'python3.11', 'python3.12', 'python3.13', 'python3.14'], ['-c']

    UNION ALL SELECT ['osascript'], ['-e']

    UNION ALL SELECT ['node'], ['-e', '--eval', '-p', '--print']

    UNION ALL SELECT ['bash', 'sh', 'zsh'], ['-c']

    UNION ALL SELECT ['perl'], ['-e', '-E']

    UNION ALL SELECT ['ruby'], ['-e']

    UNION ALL SELECT ['sed', 'gsed'], ['-e']

    UNION ALL SELECT ['curl'], ['-d', '--data', '--data-raw', '--data-binary', '--json', '--data-urlencode'])),

-- interpreters whose program is the n-th positional, unless one of unless_flags supplies it

prog_positionals AS (

  SELECT unnest(exes) AS exe, pos_no, unless_flags FROM (

    SELECT ['jq'] AS exes, 1 AS pos_no, ['-f', '--from-file'] AS unless_flags

    UNION ALL SELECT ['awk', 'gawk'], 1, ['-f']

    UNION ALL SELECT ['sed', 'gsed'], 1, ['-e', '-f']

    UNION ALL SELECT ['duckdb'], 2, ['-c', '-s', '-f'])),

-- wrappers whose real program is a later positional

wrappers AS (

  SELECT unnest(exes) AS exe, skip_pos, need_first FROM (

    SELECT ['sudo', 'nohup', 'time', 'nice', 'exec', 'command', 'caffeinate', 'npx', 'bunx', 'uvx', 'xargs', 'stdbuf', 'env', 'builtin'] AS exes, 0 AS skip_pos, NULL::VARCHAR[] AS need_first

    UNION ALL SELECT ['timeout', 'gtimeout'], 1, NULL

    UNION ALL SELECT ['uv', 'poetry', 'pnpm', 'bun', 'pipenv', 'hatch'], 1, ['run', 'exec', 'x'])),

-- argv words of every command; word_no 1 is the command name

cmd_parts AS (

  SELECT t.call_id, t.parent_id AS cmd_id, t.node_id, t.sibling_index, t.type, t.text

  FROM tok t JOIN n c ON c.call_id = t.call_id AND c.node_id = t.parent_id

  WHERE c.type = 'command'),

name_at AS (

  SELECT call_id, cmd_id, min(sibling_index) AS name_si FROM cmd_parts WHERE type = 'command_name' GROUP BY ALL),

words AS (

  SELECT p.call_id, p.cmd_id, p.node_id, p.type, p.text,

         row_number() OVER (PARTITION BY p.call_id, p.cmd_id ORDER BY p.sibling_index) AS word_no

  FROM cmd_parts p JOIN name_at a ON p.call_id = a.call_id AND p.cmd_id = a.cmd_id

  WHERE p.sibling_index >= a.name_si

    AND p.type NOT IN ('file_redirect', 'heredoc_redirect', 'herestring_redirect', 'variable_assignment', 'comment', 'ERROR')),

-- pass 1: words classified against the literal executable, to find a wrapper's target

w1 AS (

  SELECT *, first_value(parse_filename(text)) OVER (PARTITION BY call_id, cmd_id ORDER BY word_no) AS exe,

         lag(text, 1) OVER (PARTITION BY call_id, cmd_id ORDER BY word_no) AS prev1,

         lag(text, 2) OVER (PARTITION BY call_id, cmd_id ORDER BY word_no) AS prev2

  FROM words),

w1c AS (

  SELECT w1.*, word_no > 1 AND starts_with(text, '-') AND length(text) > 1 AS is_flag,

         coalesce(v1.nvals, v2.nvals) IS NOT NULL AS is_value

  FROM w1

  LEFT JOIN value_flags v1 ON v1.exe = w1.exe AND v1.flag = w1.prev1

  LEFT JOIN value_flags v2 ON v2.exe = w1.exe AND v2.flag = w1.prev2 AND v2.nvals = 2),

wpos1 AS (

  SELECT *, word_no > 1 AND NOT is_flag AND NOT is_value AS is_positional,

         sum((word_no > 1 AND NOT is_flag AND NOT is_value)::int) OVER (PARTITION BY call_id, cmd_id ORDER BY word_no) AS pos_run

  FROM w1c),

pos1 AS (SELECT call_id, cmd_id, pos_run AS pos_no, word_no, text FROM wpos1 WHERE is_positional),

cmd_head AS (SELECT call_id, cmd_id, exe, text AS path FROM wpos1 WHERE word_no = 1),

wrap_target AS (

  SELECT h.call_id, h.cmd_id, min(p.word_no) AS eff_start

  FROM cmd_head h JOIN wrappers wr ON wr.exe = h.exe

  LEFT JOIN pos1 first_pos ON first_pos.call_id = h.call_id AND first_pos.cmd_id = h.cmd_id AND first_pos.pos_no = 1

  JOIN pos1 p ON p.call_id = h.call_id AND p.cmd_id = h.cmd_id AND p.pos_no = wr.skip_pos + 1

  WHERE coalesce(list_contains(wr.need_first, first_pos.text), wr.need_first IS NULL)

  GROUP BY ALL),

eff AS (

  SELECT h.call_id, h.cmd_id, h.exe, h.path, coalesce(t.eff_start, 1) AS eff_start,

         parse_filename(coalesce(w.text, h.path)) AS eff_exe

  FROM cmd_head h

  LEFT JOIN wrap_target t ON t.call_id = h.call_id AND t.cmd_id = h.cmd_id

  LEFT JOIN words w ON w.call_id = h.call_id AND w.cmd_id = h.cmd_id AND w.word_no = t.eff_start),

-- pass 2: words of the effective program; e_no 1 is its name

w2 AS (

  SELECT words.*, eff.eff_exe AS exe, words.word_no - eff.eff_start + 1 AS e_no,

         lag(words.text, 1) OVER (PARTITION BY words.call_id, words.cmd_id ORDER BY words.word_no) AS prev1,

         lag(words.text, 2) OVER (PARTITION BY words.call_id, words.cmd_id ORDER BY words.word_no) AS prev2

  FROM words JOIN eff ON eff.call_id = words.call_id AND eff.cmd_id = words.cmd_id

  WHERE words.word_no >= eff.eff_start),

w2c AS (

  SELECT w2.*, e_no > 1 AND starts_with(text, '-') AND length(text) > 1 AS is_flag,

         e_no > 1 AND coalesce(v1.nvals, v2.nvals) IS NOT NULL AS is_value

  FROM w2

  LEFT JOIN value_flags v1 ON v1.exe = w2.exe AND v1.flag = w2.prev1

  LEFT JOIN value_flags v2 ON v2.exe = w2.exe AND v2.flag = w2.prev2 AND v2.nvals = 2),

wpos2 AS (

  SELECT *, e_no > 1 AND NOT is_flag AND NOT is_value AS is_positional,

         sum((e_no > 1 AND NOT is_flag AND NOT is_value)::int) OVER (PARTITION BY call_id, cmd_id ORDER BY e_no) AS pos_run

  FROM w2c),

-- the statement right before a `&` token runs in the background

bg AS (

  SELECT u.call_id, u.node_id, u.descendant_count

  FROM n amp JOIN n u ON u.call_id = amp.call_id AND u.parent_id = amp.parent_id AND u.sibling_index = amp.sibling_index - 1

  WHERE amp.type = '&'),

ctx AS (

  SELECT c.call_id, c.node_id AS cmd_id,

         list_filter(list(a.type ORDER BY a.depth), lambda x: x IS NOT NULL) AS ancestors

  FROM n c LEFT JOIN n a ON a.call_id = c.call_id

     AND a.node_id < c.node_id AND c.node_id <= a.node_id + a.descendant_count

     AND a.type IN ('command_substitution', 'process_substitution', 'subshell', 'pipeline', 'for_statement',

                    'c_style_for_statement', 'while_statement', 'if_statement', 'case_statement', 'function_definition',

                    'heredoc_redirect', 'compound_statement', 'negated_command', 'ERROR')

  WHERE c.type = 'command' GROUP BY ALL),

bgc AS (

  SELECT DISTINCT c.call_id, c.node_id AS cmd_id

  FROM n c JOIN bg ON bg.call_id = c.call_id AND c.node_id >= bg.node_id AND c.node_id <= bg.node_id + bg.descendant_count

  WHERE c.type = 'command'),

raw_words AS (SELECT call_id, cmd_id, list(text ORDER BY word_no) AS words FROM words GROUP BY ALL),

eff_words AS (

  SELECT call_id, cmd_id,

         list_filter(list(CASE WHEN is_flag THEN text END ORDER BY e_no), lambda x: x IS NOT NULL) AS flags,

         list_filter(list(CASE WHEN is_positional THEN text END ORDER BY e_no), lambda x: x IS NOT NULL) AS positionals

  FROM wpos2 GROUP BY ALL),

prefix_assigns AS (

  SELECT a.call_id, a.parent_id AS cmd_id, list(v.text ORDER BY a.sibling_index) AS prefix_env

  FROM n a JOIN tok v ON v.call_id = a.call_id AND v.parent_id = a.node_id

  WHERE a.type = 'variable_assignment' AND v.type = 'variable_name' GROUP BY ALL),

cmds AS (

  SELECT eff.call_id, eff.cmd_id, c.start_line AS line, eff.exe, eff.path, eff.eff_exe, raw_words.words,

         eff_words.flags, eff_words.positionals,

         eff_words.positionals[1] AS subcommand, eff_words.positionals[2] AS subcommand2,

         prefix_assigns.prefix_env, ctx.ancestors,

         list_contains(ctx.ancestors, 'command_substitution') AS in_substitution,

         list_contains(ctx.ancestors, 'pipeline') AS in_pipeline,

         list_contains(ctx.ancestors, 'ERROR') AS in_error,

         bgc.cmd_id IS NOT NULL AS backgrounded

  FROM eff

  JOIN n c ON c.call_id = eff.call_id AND c.node_id = eff.cmd_id

  JOIN raw_words ON raw_words.call_id = eff.call_id AND raw_words.cmd_id = eff.cmd_id

  LEFT JOIN eff_words ON eff_words.call_id = eff.call_id AND eff_words.cmd_id = eff.cmd_id

  LEFT JOIN ctx ON ctx.call_id = eff.call_id AND ctx.cmd_id = eff.cmd_id

  LEFT JOIN bgc ON bgc.call_id = eff.call_id AND bgc.cmd_id = eff.cmd_id

  LEFT JOIN prefix_assigns ON prefix_assigns.call_id = eff.call_id AND prefix_assigns.cmd_id = eff.cmd_id),

redirs AS (

  SELECT r.call_id, r.node_id, r.parent_id,

         max(CASE WHEN c.type = 'file_descriptor' THEN c.text END) AS fd,

         max(CASE WHEN c.type IN ('>', '>>', '<', '>&', '&>', '&>>', '<&', '>|', '<>', '>&-', '<&-') THEN c.type END) AS op,

         arg_max(c.text, CASE WHEN c.type NOT IN ('>', '>>', '<', '>&', '&>', '&>>', '<&', '>|', '<>', '>&-', '<&-', 'file_descriptor', 'ERROR') THEN c.sibling_index END) AS target

  FROM n r JOIN tok c ON c.call_id = r.call_id AND c.parent_id = r.node_id

  WHERE r.type = 'file_redirect'

  GROUP BY ALL),

-- heredocs: the command fed by the body, the commands it pipes into, and the effective interpreter

hd AS (SELECT call_id, node_id, parent_id FROM n WHERE type = 'heredoc_redirect'),

hd_parts AS (

  SELECT hd.call_id, hd.node_id, hd.parent_id,

         max(CASE WHEN c.type = 'heredoc_start' THEN c.peek END) AS delimiter,

         max(CASE WHEN c.type = 'heredoc_body' THEN c.peek END) AS body,

         max(CASE WHEN c.type = 'pipeline' THEN c.node_id END) AS pipe_id,

         max(CASE WHEN c.type = 'pipeline' THEN c.descendant_count END) AS pipe_desc

  FROM hd JOIN n c ON c.call_id = hd.call_id AND c.parent_id = hd.node_id GROUP BY ALL),

-- the command a heredoc / here-string feeds: its parent command, or the statement it is attached to

-- (that statement itself, or the last command directly inside it when it is a list or pipeline)

rd AS (SELECT call_id, node_id, parent_id FROM n WHERE type IN ('heredoc_redirect', 'herestring_redirect')),

rd_owner_cand AS (

  SELECT rd.call_id, rd.node_id, p.node_id AS cmd_id

  FROM rd JOIN n p ON p.call_id = rd.call_id AND p.node_id = rd.parent_id

  WHERE p.type = 'command'

  UNION ALL

  SELECT rd.call_id, rd.node_id, s.node_id

  FROM rd JOIN n s ON s.call_id = rd.call_id AND s.parent_id = rd.parent_id AND s.sibling_index = 0

  WHERE s.type = 'command'

  UNION ALL

  SELECT rd.call_id, rd.node_id, f.node_id

  FROM rd JOIN n s ON s.call_id = rd.call_id AND s.parent_id = rd.parent_id AND s.sibling_index = 0

  JOIN n f ON f.call_id = s.call_id AND f.parent_id = s.node_id

  WHERE f.type = 'command'),

rd_owner AS (SELECT call_id, node_id, max(cmd_id) AS cmd_id FROM rd_owner_cand GROUP BY ALL),

hd_consumers AS (

  SELECT hp.call_id, hp.node_id, list(cm.eff_exe ORDER BY cm.cmd_id) AS consumers

  FROM hd_parts hp JOIN cmds cm ON cm.call_id = hp.call_id AND cm.cmd_id > hp.pipe_id AND cm.cmd_id <= hp.pipe_id + hp.pipe_desc

  GROUP BY ALL),

hd_writes AS (

  SELECT hd.call_id, hd.node_id, list(r.target ORDER BY r.node_id) AS writes_to

  FROM hd JOIN redirs r ON r.call_id = hd.call_id AND r.parent_id = hd.parent_id

  WHERE r.op IN ('>', '>>', '&>', '&>>', '>|')

  GROUP BY ALL),

heredocs AS (

  SELECT hp.call_id, hp.node_id, hp.delimiter, hp.body, fc.eff_exe AS feeder, hc.consumers,

         coalesce(hc.consumers[-1], fc.eff_exe) AS interpreter, hw.writes_to

  FROM hd_parts hp

  LEFT JOIN rd_owner ro ON ro.call_id = hp.call_id AND ro.node_id = hp.node_id

  LEFT JOIN cmds fc ON fc.call_id = ro.call_id AND fc.cmd_id = ro.cmd_id

  LEFT JOIN hd_consumers hc ON hc.call_id = hp.call_id AND hc.node_id = hp.node_id

  LEFT JOIN hd_writes hw ON hw.call_id = hp.call_id AND hw.node_id = hp.node_id),

-- embedded programs: a program flag's value, a positional program, a heredoc body, a here-string

cmd_flag_lists AS (SELECT call_id, cmd_id, list(text) AS flags FROM wpos2 WHERE is_flag GROUP BY ALL),

hs AS (SELECT call_id, node_id, parent_id FROM n WHERE type = 'herestring_redirect'),

embedded AS (

  SELECT x.call_id, x.node_id AS at_node, x.exe AS interpreter, x.text AS via, y.text AS program

  FROM wpos2 x JOIN prog_flags pf ON pf.exe = x.exe AND pf.flag = x.text

  JOIN wpos2 y ON y.call_id = x.call_id AND y.cmd_id = x.cmd_id AND y.e_no = x.e_no + 1

  WHERE x.e_no > 1

  UNION ALL

  SELECT w.call_id, w.node_id, w.exe, 'positional', w.text

  FROM wpos2 w JOIN prog_positionals pp ON pp.exe = w.exe AND pp.pos_no = w.pos_run

  LEFT JOIN cmd_flag_lists cf ON cf.call_id = w.call_id AND cf.cmd_id = w.cmd_id

  WHERE w.is_positional AND NOT list_has_any(coalesce(cf.flags, []), pp.unless_flags)

  UNION ALL

  SELECT call_id, node_id, interpreter, 'heredoc', body FROM heredocs

  UNION ALL

  SELECT hs.call_id, hs.node_id, cm.eff_exe, 'herestring', arg_max(t.text, t.sibling_index)

  FROM hs JOIN tok t ON t.call_id = hs.call_id AND t.parent_id = hs.node_id

  LEFT JOIN rd_owner ro ON ro.call_id = hs.call_id AND ro.node_id = hs.node_id

  LEFT JOIN cmds cm ON cm.call_id = ro.call_id AND cm.cmd_id = ro.cmd_id

  WHERE t.type <> '<<<'

  GROUP BY ALL),

shape AS (

  SELECT call_id,

         len(list(node_id)) AS node_count,

         max(depth) AS max_depth,

         max(end_line) AS line_count,

         sum((type = 'ERROR')::int) AS error_count,

         sum((children_count = 0 AND length(peek) = 0 AND type NOT IN ('heredoc_body', 'string_content', 'program'))::int) AS zero_width_leaves,

         sum((type = 'pipeline')::int) AS pipeline_count,

         sum((type = '&&')::int) AS and_count,

         sum((type = '||')::int) AS or_count,

         sum((type = 'heredoc_redirect')::int) AS heredoc_count,

         sum((type = 'herestring_redirect')::int) AS herestring_count,

         sum((type = 'command_substitution')::int) AS command_substitution_count,

         sum((type = 'process_substitution')::int) AS process_substitution_count,

         sum((type = 'subshell')::int) AS subshell_count,

         sum((type IN ('for_statement', 'c_style_for_statement', 'while_statement'))::int) AS loop_count,

         sum((type IN ('if_statement', 'case_statement', 'test_command'))::int) AS conditional_count,

         sum((type = 'function_definition')::int) AS function_count,

         sum((type = 'comment')::int) AS comment_count,

         sum((type = '&')::int) AS background_count,

         sum((depth = 1 AND type NOT IN (';', '&', 'comment'))::int) AS statement_count

  FROM n GROUP BY ALL),

pipe_sizes AS (

  SELECT p.call_id, p.node_id, sum((c.type = 'command')::int) AS k

  FROM n p JOIN n c ON c.call_id = p.call_id AND c.parent_id = p.node_id

  WHERE p.type = 'pipeline' GROUP BY ALL),

pipes AS (SELECT call_id, max(k) AS max_pipeline_length FROM pipe_sizes GROUP BY ALL),

first_err AS (SELECT call_id, min(node_id) AS err_id FROM n WHERE type = 'ERROR' GROUP BY ALL),

err AS (

  SELECT fe.call_id,

         printf('line %d: %s', e.start_line, left(e.peek, 160)) AS parse_error,

         printf('%s > ERROR > %s', p.type, coalesce(arg_min(c.type, c.sibling_index), 'leaf')) AS error_kind

  FROM first_err fe JOIN n e ON e.call_id = fe.call_id AND e.node_id = fe.err_id

  JOIN n p ON p.call_id = e.call_id AND p.node_id = e.parent_id

  LEFT JOIN n c ON c.call_id = e.call_id AND c.parent_id = e.node_id

  GROUP BY fe.call_id, e.start_line, e.peek, p.type),

cmd_agg AS (

  SELECT call_id,

         list(exe ORDER BY cmd_id) AS commands,

         list(path ORDER BY cmd_id) AS command_paths,

         list(eff_exe ORDER BY cmd_id) AS effective_commands,

         list(words ORDER BY cmd_id) AS command_words,

         list({'exe': exe, 'eff_exe': eff_exe, 'path': path, 'line': line, 'flags': flags, 'positionals': positionals,

               'subcommand': subcommand, 'subcommand2': subcommand2, 'prefix_env': prefix_env, 'ancestors': ancestors,

               'in_substitution': in_substitution, 'in_pipeline': in_pipeline, 'in_error': in_error,

               'backgrounded': backgrounded} ORDER BY cmd_id) AS command_details,

         list_distinct(list(eff_exe)) AS distinct_commands,

         list_filter(list(CASE WHEN eff_exe = 'git' THEN subcommand END ORDER BY cmd_id), lambda x: x IS NOT NULL) AS git_subcommands,

         list_filter(list(CASE WHEN eff_exe = 'gh' THEN concat_ws(' ', subcommand, subcommand2) END ORDER BY cmd_id), lambda x: x IS NOT NULL) AS gh_subcommands,

         flatten(list_filter(list(CASE WHEN eff_exe = 'curl' THEN positionals END ORDER BY cmd_id), lambda x: x IS NOT NULL)) AS curl_urls,

         list_filter(list(CASE WHEN eff_exe = 'duckdb' THEN coalesce(subcommand, '') END ORDER BY cmd_id), lambda x: x IS NOT NULL) AS duckdb_databases,

         list_filter(list(CASE WHEN exe = 'cd' THEN coalesce(words[2], '') END ORDER BY cmd_id), lambda x: x IS NOT NULL) AS cd_targets,

         list_filter(list(CASE WHEN eff_exe = 'sleep' THEN words[-1] END ORDER BY cmd_id), lambda x: x IS NOT NULL) AS sleep_args,

         flatten(list_filter(list(CASE WHEN eff_exe = 'tee' THEN positionals END ORDER BY cmd_id), lambda x: x IS NOT NULL)) AS tee_targets,

         list_filter(list(CASE WHEN backgrounded THEN eff_exe END ORDER BY cmd_id), lambda x: x IS NOT NULL) AS background_commands,

         list_filter(list(CASE WHEN in_substitution THEN eff_exe END ORDER BY cmd_id), lambda x: x IS NOT NULL) AS substitution_commands,

         list_filter(list(CASE WHEN in_error THEN eff_exe END ORDER BY cmd_id), lambda x: x IS NOT NULL) AS commands_in_error,

         list_distinct(flatten(list(coalesce(prefix_env, [])))) AS prefix_env_vars,

         len(list(cmd_id)) AS command_count

  FROM cmds GROUP BY ALL),

git_dirs AS (

  SELECT y.call_id, list(y.text ORDER BY y.node_id) AS git_dirs

  FROM wpos2 x JOIN wpos2 y ON y.call_id = x.call_id AND y.cmd_id = x.cmd_id AND y.e_no = x.e_no + 1

  WHERE x.exe = 'git' AND x.text = '-C' GROUP BY ALL),

redir_agg AS (

  SELECT call_id, list({'fd': fd, 'op': op, 'target': target} ORDER BY node_id) AS redirects,

         list_filter(list(CASE WHEN op IN ('>', '>>', '&>', '&>>', '>|') THEN target END ORDER BY node_id), lambda x: x IS NOT NULL) AS write_targets

  FROM redirs GROUP BY ALL),

hd_agg AS (

  SELECT call_id, list(interpreter ORDER BY node_id) AS heredoc_interpreters,

         list({'delimiter': delimiter, 'feeder': feeder, 'consumers': consumers, 'interpreter': interpreter,

               'writes_to': writes_to, 'body_len': length(body)} ORDER BY node_id) AS heredocs

  FROM heredocs GROUP BY ALL),

emb_agg AS (

  SELECT call_id, list({'interpreter': interpreter, 'via': via, 'program': program} ORDER BY at_node) AS embedded_programs,

         list_distinct(list(interpreter)) AS embedded_interpreters

  FROM embedded GROUP BY ALL),

assign_agg AS (

  SELECT a.call_id, list(DISTINCT v.text ORDER BY v.text) AS assigned_vars

  FROM n a JOIN tok v ON v.call_id = a.call_id AND v.parent_id = a.node_id

  WHERE a.type = 'variable_assignment' AND v.type = 'variable_name' GROUP BY ALL)

SELECT src.call_id, src.session, src.ts, src.subagent, src.next_prompt_corrects,

       json_extract_string(src.input, '$.description') AS description,

       json_extract(src.input, '$.run_in_background')::BOOLEAN AS run_in_background,

       json_extract(src.input, '$.timeout')::BIGINT AS tool_timeout_ms,

       length(json_extract_string(src.input, '$.command')) AS command_len,

       shape.line_count,

       shape.error_count = 0 AND shape.zero_width_leaves = 0 AS parse_ok,

       shape.error_count, shape.zero_width_leaves,

       err.parse_error, err.error_kind,

       shape.node_count, shape.max_depth, shape.statement_count,

       coalesce(cmd_agg.commands, []) AS commands,

       coalesce(cmd_agg.command_paths, []) AS command_paths,

       coalesce(cmd_agg.effective_commands, []) AS effective_commands,

       coalesce(cmd_agg.distinct_commands, []) AS distinct_commands,

       coalesce(cmd_agg.command_words, []) AS command_words,

       cmd_agg.command_details,

       coalesce(cmd_agg.command_count, 0) AS command_count,

       shape.pipeline_count, coalesce(pipes.max_pipeline_length, 0) AS max_pipeline_length,

       shape.and_count, shape.or_count,

       shape.heredoc_count > 0 AS has_heredoc, shape.heredoc_count,

       coalesce(hd_agg.heredoc_interpreters, []) AS heredoc_interpreters, hd_agg.heredocs,

       shape.herestring_count,

       coalesce(redir_agg.redirects, []) AS redirects,

       list_distinct(coalesce(redir_agg.write_targets, []) || coalesce(cmd_agg.tee_targets, [])) AS writes_files,

       coalesce(emb_agg.embedded_programs, []) AS embedded_programs,

       coalesce(emb_agg.embedded_interpreters, []) AS embedded_interpreters,

       shape.command_substitution_count, shape.process_substitution_count, shape.subshell_count,

       shape.loop_count, shape.conditional_count, shape.function_count, shape.comment_count,

       shape.background_count > 0 AS launches_background,

       coalesce(cmd_agg.background_commands, []) AS background_commands,

       coalesce(cmd_agg.substitution_commands, []) AS substitution_commands,

       coalesce(cmd_agg.commands_in_error, []) AS commands_in_error,

       list_contains(coalesce(cmd_agg.effective_commands, []), 'sleep') AS uses_sleep,

       coalesce(cmd_agg.sleep_args, []) AS sleep_args,

       coalesce(cmd_agg.git_subcommands, []) AS git_subcommands,

       coalesce(git_dirs.git_dirs, []) AS git_dirs,

       coalesce(cmd_agg.gh_subcommands, []) AS gh_subcommands,

       coalesce(cmd_agg.curl_urls, []) AS curl_urls,

       coalesce(cmd_agg.duckdb_databases, []) AS duckdb_databases,

       coalesce(cmd_agg.cd_targets, []) AS cd_targets,

       coalesce(cmd_agg.prefix_env_vars, []) AS prefix_env_vars,

       coalesce(assign_agg.assigned_vars, []) AS assigned_vars

FROM src

JOIN shape ON shape.call_id = src.call_id

LEFT JOIN pipes ON pipes.call_id = src.call_id

LEFT JOIN err ON err.call_id = src.call_id

LEFT JOIN cmd_agg ON cmd_agg.call_id = src.call_id

LEFT JOIN git_dirs ON git_dirs.call_id = src.call_id

LEFT JOIN redir_agg ON redir_agg.call_id = src.call_id

LEFT JOIN hd_agg ON hd_agg.call_id = src.call_id

LEFT JOIN emb_agg ON emb_agg.call_id = src.call_id

LEFT JOIN assign_agg ON assign_agg.call_id = src.call_id
;
