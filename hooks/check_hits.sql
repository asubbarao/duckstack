CREATE OR REPLACE VIEW check_hits AS
WITH facts AS (FROM toolcall_facts)
SELECT 'agent_not_opus' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Agent' AND agent_model NOT IN ('opus')), false)
UNION ALL
SELECT 'agent_without_model' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Agent' AND agent_model IS NULL AND agent_subagent_type IS DISTINCT FROM 'fork'), false)
UNION ALL
SELECT 'ask_after_reading' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'AskUserQuestion'), false)
UNION ALL
SELECT 'backend_duckdb_file' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name IN ('Edit', 'Write') AND file_ext = '.py' AND list_has_all(file_path_parts, ['platform', 'backend'])), false)
UNION ALL
SELECT 'bare_python' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(bash_raw_commands, ['python', 'python3', 'pip', 'pip3', 'virtualenv'])), false)
UNION ALL
SELECT 'bash_text_munging' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(bash_pipeline_commands, ['sed', 'gsed', 'awk', 'gawk', 'cut', 'tr'])), false)
UNION ALL
SELECT 'bash_text_readers' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> CASE d.eff_exe WHEN 'cat' THEN len(d.positionals) > 0 ELSE d.eff_exe IN ('grep', 'egrep', 'rg', 'head', 'tail', 'find', 'less') END)) > 0), false)
UNION ALL
SELECT 'claude_codex_parity' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name IN ('Edit', 'Write') AND file_name IN ('CLAUDE.md', 'AGENTS.md', 'SKILL.md')), false)
UNION ALL
SELECT 'commit_author_email' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(bash_git_subcommands, 'commit')), false)
UNION ALL
SELECT 'commit_generated_files' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(bash_git_subcommands, 'commit')), false)
UNION ALL
SELECT 'copy_round_trip' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_verbs, 'COPY')), false)
UNION ALL
SELECT 'curl_to_dev' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_curl_uris, u -> u.host IN ('localhost', '127.0.0.1', '[::1]') AND u.port IN ('9494', '9495'))) > 0), false)
UNION ALL
SELECT 'curl_to_dev__mcp' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_curl_uris, u -> u.host IN ('localhost', '127.0.0.1', '[::1]') AND u.port IN ('9494', '9495'))) > 0), false)
UNION ALL
SELECT 'detached_launcher' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> CASE d.exe WHEN 'nohup' THEN d.eff_exe NOT IN ('sh', 'bash', 'zsh') ELSE d.exe IN ('setsid', 'disown') END)) > 0), false)
UNION ALL
SELECT 'dev_listener_launch' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(bash_background_commands, 'duckdb')), false)
UNION ALL
SELECT 'dispatched_post_readonly' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['selfdispatch', 'quackapi_post'])), false)
UNION ALL
SELECT 'duckdb_file_database' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_duckdb_databases, x -> substr(parse_filename(x), length(parse_filename(x, true)) + 1) IN ('.duckdb', '.db', '.ddb'))) > 0), false)
UNION ALL
SELECT 'duckdb_init_flag' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'duckdb' AND list_has_any(d.flags, ['-init', '-no-init']))) > 0
   AND len(list_filter(flatten(list_transform(bash_command_details, d -> coalesce(d.positionals, []))), x -> contains(x, 'LaunchAgents/com.inframe.'))) = 0), false)
UNION ALL
SELECT 'duckdb_init_flag__plist' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'duckdb' AND list_has_any(d.flags, ['-init', '-no-init']))) > 0
   AND len(list_filter(flatten(list_transform(bash_command_details, d -> coalesce(d.positionals, []))), x -> contains(x, 'LaunchAgents/com.inframe.'))) > 0), false)
UNION ALL
SELECT 'duckdb_opens_dev_file' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_duckdb_databases, x -> parse_filename(x) IN ('dev.duckdb', 'dev.duckdb.wal') AND parse_path(x)[-2] = '.duck')) > 0), false)
UNION ALL
SELECT 'flow_gate' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((CASE WHEN tool_name = 'Bash' THEN len(list_filter(bash_command_details, d -> CASE d.eff_exe WHEN 'gh' THEN d.subcommand = 'pr' AND d.subcommand2 = 'create' WHEN 'git' THEN d.subcommand = 'push' ELSE false END)) > 0 ELSE tool_name IN ('mcp__linear__save_issue', 'mcp__linear__save_project') END), false)
UNION ALL
SELECT 'gh_api_fetch' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'api' AND len(list_filter(d.positionals, p -> list_has_any(parse_path(p), ['contents', 'blobs', 'trees', 'raw']))) > 0)) > 0), false)
UNION ALL
SELECT 'gh_auth_switch' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'auth' AND d.subcommand2 = 'switch' AND NOT list_contains(d.positionals, 'asubbarao-ifr'))) > 0), false)
UNION ALL
SELECT 'gh_pr_create_no_repo' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 = 'create' AND NOT list_has_any(d.flags, ['--repo', '-R']))) > 0), false)
UNION ALL
SELECT 'gh_pr_create_upstream' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 = 'create')) > 0 AND len(list_filter(bash_gh_repos, r -> parse_path(r)[1] NOT IN ('inframe-risk', 'asubbarao'))) > 0), false)
UNION ALL
SELECT 'gh_pr_draft' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 = 'create' AND list_has_any(d.flags, ['--draft', '-d']))) > 0), false)
UNION ALL
SELECT 'gh_pr_merge_needs_yes' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 = 'merge')) > 0), false)
UNION ALL
SELECT 'gh_pr_merge_no_head_match' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 = 'merge' AND NOT list_contains(d.flags, '--match-head-commit'))) > 0), false)
UNION ALL
SELECT 'gh_pr_reviewer' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 IN ('create', 'edit') AND list_has_any(d.flags, ['--reviewer', '-r', '--add-reviewer']))) > 0), false)
UNION ALL
SELECT 'gh_repo_fork' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(bash_gh_subcommands, 'repo fork')), false)
UNION ALL
SELECT 'git_checkout_paths' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'git' AND d.subcommand = 'checkout' AND list_contains(d.flags, '--'))) > 0), false)
UNION ALL
SELECT 'git_clone' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(bash_git_subcommands, 'clone')), false)
UNION ALL
SELECT 'git_log_cli' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(bash_git_subcommands, 'log')), false)
UNION ALL
SELECT 'git_read_cli' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> CASE d.eff_exe WHEN 'git' THEN d.subcommand IN ('show', 'restore', 'diff') WHEN 'diff' THEN true ELSE false END)) > 0), false)
UNION ALL
SELECT 'git_skip_verify' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'git' AND CASE d.subcommand WHEN 'commit' THEN list_has_any(d.flags, ['--no-verify', '-n']) ELSE list_contains(d.flags, '--no-verify') END)) > 0), false)
UNION ALL
SELECT 'host_command_text' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(bash_pipeline_commands, ['ps', 'lsof', 'netstat', 'df', 'du'])), false)
UNION ALL
SELECT 'house_rules_in_brief' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Agent' AND agent_subagent_type IS DISTINCT FROM 'fork' AND NOT contains(coalesce(agent_prompt, ''), 'DuckDB is part of the stack by decision')), false)
UNION ALL
SELECT 'instruction_mirrors' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name IN ('Edit', 'Write') AND file_name IN ('CLAUDE.md', 'AGENTS.md')), false)
UNION ALL
SELECT 'launchctl' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'launchctl' AND d.subcommand NOT IN ('list', 'print', 'print-disabled', 'blame', 'examine', 'dumpstate', 'help'))) > 0), false)
UNION ALL
SELECT 'linear_title_tool_names' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name IN ('mcp__linear__save_issue', 'mcp__linear__save_project', 'mcp__5b54d934-0421-4702-94fb-9066e43667a9__save_issue') AND list_has_any(linear_title_words,['duckdb', 'sql', 'mcp', 'quackapi', 'shellfs', 'parquet', 'json', 'jq', 'regex', 'postgres', 'python'])), false)
UNION ALL
SELECT 'named_model_and_count' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Agent'), false)
UNION ALL
SELECT 'one_statement_job' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_verbs, 'COPY')), false)
UNION ALL
SELECT 'pattern_kill' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(bash_commands, ['pkill', 'killall'])), false)
UNION ALL
SELECT 'personal_repo_owner' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(bash_git_subcommands, 'push')), false)
UNION ALL
SELECT 'pr_duplicate' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 = 'create')) > 0), false)
UNION ALL
SELECT 'pr_size' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 = 'create')) > 0), false)
UNION ALL
SELECT 'pr_team_scope' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'gh' AND d.subcommand = 'pr' AND d.subcommand2 = 'create')) > 0), false)
UNION ALL
SELECT 'raw_transcript_read' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((file_ext = '.jsonl' AND list_has_any(file_path_parts, ['.claude', '.codex'])), false)
UNION ALL
SELECT 'review_only_no_writes' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name IN ('Edit', 'Write', 'Agent') ), false)
UNION ALL
SELECT 'rm_outside_scratch' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> d.eff_exe = 'rm' AND len(list_filter(d.positionals, p -> parse_path(p)[1] IN ('/', '~') AND NOT list_has_any(parse_path(p), ['scratchpad', 'tmp', 'private', 'luna_runs']))) > 0)) > 0), false)
UNION ALL
SELECT 'search_before_new_file' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Write' AND list_has_any(file_path_parts, ['skills', 'server'])), false)
UNION ALL
SELECT 'shared_block_read_first' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Edit' AND file_name IN ('setup.sql', 'middleware.sql')), false)
UNION ALL
SELECT 'shell_loop' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((bash_loop_count > 0 AND NOT bash_uses_sleep), false)
UNION ALL
SELECT 'skill_examples_compliant' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name IN ('Edit', 'Write') AND file_ext = '.md' AND list_contains(file_path_parts, 'skills')), false)
UNION ALL
SELECT 'slack_send' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name IN ('mcp__slack__slack_send_message', 'mcp__slack__slack_schedule_message', 'mcp__dfa81f6c-2e15-4417-8bdf-54a0fe3e18fc__slack_send_message', 'mcp__dfa81f6c-2e15-4417-8bdf-54a0fe3e18fc__slack_schedule_message')), false)
UNION ALL
SELECT 'sleep_poll_loop' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((bash_uses_sleep AND bash_loop_count > 0), false)
UNION ALL
SELECT 'sleep_wait' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((bash_uses_sleep AND bash_loop_count = 0), false)
UNION ALL
SELECT 'sql_any_value' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['any_value', 'arbitrary'])), false)
UNION ALL
SELECT 'sql_attach_on_dev' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_sources, 'tool') AND list_has_any(sql_verbs, ['ATTACH', 'DETACH'])), false)
UNION ALL
SELECT 'sql_base64' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['to_base64', 'from_base64', 'base64'])), false)
UNION ALL
SELECT 'sql_char_code_newline' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name IN ('chr', 'char') AND list_contains(f.literals, '10'))) > 0), false)
UNION ALL
SELECT 'sql_char_code_quotes' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name IN ('chr', 'char') AND list_has_any(f.literals, ['39', '34']))) > 0), false)
UNION ALL
SELECT 'sql_coalesce_empty_default' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name = 'operator_coalesce' AND f.args[-1] = 'constant' AND f.literals[-1] = '')) > 0), false)
UNION ALL
SELECT 'sql_comma_join' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_comma_join), false)
UNION ALL
SELECT 'sql_create_macro' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_statement_kinds, 'create_macro')), false)
UNION ALL
SELECT 'sql_create_macro__dev' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_statement_kinds, 'create_macro')), false)
UNION ALL
SELECT 'sql_create_macro__dispatch' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_statement_kinds, 'create_macro')), false)
UNION ALL
SELECT 'sql_create_macro__tooling' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_statement_kinds, 'create_macro')), false)
UNION ALL
SELECT 'sql_cross_join_not_unnest' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_cross_join_not_unnest), false)
UNION ALL
SELECT 'sql_dispatch_direct_post' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name = 'quackapi_post' AND len(list_filter(f.literals, l -> contains(l, ':9495/sql'))) > 0)) > 0), false)
UNION ALL
SELECT 'sql_dispatch_range_source' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_functions, 'selfdispatch') AND list_has_any(list_concat(sql_table_functions, sql_functions), ['range', 'generate_series'])), false)
UNION ALL
SELECT 'sql_dispatch_shape' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_functions, 'selfdispatch') AND NOT (list_has_any(sql_functions, ['array_agg', 'list']) AND sql_has_unnest_cross_join AND len(list_filter(sql_function_calls, f -> f.name = 'tera_render' AND list_has_any(f.literals, ['shell.tera', 'sql.tera', 'bash_loop_fallback_method.tera']))) > 0)), false)
UNION ALL
SELECT 'sql_drop_table' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains([h[1:2] FOR h IN sql_heads], ['DROP', 'TABLE'])), false)
UNION ALL
SELECT 'sql_file_too_long' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Write' AND file_ext = '.sql' AND write_lines > 80), false)
UNION ALL
SELECT 'sql_filter_clause' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_filter_clause), false)
UNION ALL
SELECT 'sql_first_last_value' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['first_value', 'last_value'])), false)
UNION ALL
SELECT 'sql_getenv_wrapped' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name IN ('operator_coalesce', 'nullif') AND list_contains(f.args, 'getenv'))) > 0), false)
UNION ALL
SELECT 'sql_hand_typed_structure' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name IN ('from_json', 'from_json_strict', 'json_transform', 'json_transform_strict') AND f.args[2] = 'constant')) > 0), false)
UNION ALL
SELECT 'sql_hardcoded_user_path' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(flatten(list_concat([t.literals FOR t IN sql_table_function_calls], [f.literals FOR f IN sql_function_calls])), l -> contains(l, '/Users/'))) > 0), false)
UNION ALL
SELECT 'sql_http_client' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['http_post', 'http_get', 'http_post_form', 'http_head', 'http_put', 'http_delete'])), false)
UNION ALL
SELECT 'sql_http_server' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['httpserve_start', 'httpserve_stop', 'httpserve'])), false)
UNION ALL
SELECT 'sql_join_on_constant' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_join_on_constant), false)
UNION ALL
SELECT 'sql_json_each' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_table_functions, 'json_each')), false)
UNION ALL
SELECT 'sql_json_extract' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['json_extract', 'json_extract_string', 'json_extract_path', 'json_extract_path_text'])), false)
UNION ALL
SELECT 'sql_lateral_not_allowlisted' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_lateral_function_join AND NOT list_has_all(['read_lines_lateral', 'git_read_each', 'git_log_each', 'git_tree_each', 'git_diff_tree_each', 'json_tree', 'unnest'], sql_lateral_functions)), false)
UNION ALL
SELECT 'sql_left_join_lateral' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_left_join_lateral), false)
UNION ALL
SELECT 'sql_limit_one' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_limit_1), false)
UNION ALL
SELECT 'sql_list_transform_range' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name IN ('list_transform', 'list_apply', 'apply') AND list_has_any(f.args[1:1], ['range', 'generate_series']))) > 0), false)
UNION ALL
SELECT 'sql_lossy_case_pivot' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name IN ('max', 'min', 'first', 'last') AND list_contains(f.args, 'case'))) > 0), false)
UNION ALL
SELECT 'sql_materialized_cte' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_materialized_cte), false)
UNION ALL
SELECT 'sql_nested_replace' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name = 'replace' AND list_contains(f.args, 'replace'))) > 0), false)
UNION ALL
SELECT 'sql_new_table' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_statement_kinds, 'create_table') AND NOT list_contains(sql_sources, 'file')), false)
UNION ALL
SELECT 'sql_new_table_in_file' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_statement_kinds, 'create_table') AND list_contains(sql_sources, 'file')), false)
UNION ALL
SELECT 'sql_or_of_patterns' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_or_of_patterns), false)
UNION ALL
SELECT 'sql_or_predicate' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_or_node_count > 0 AND NOT sql_has_or_of_patterns), false)
UNION ALL
SELECT 'sql_pattern_functions' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['regexp_matches', 'regexp_full_match', 'regexp_replace', 'regexp_extract', 'regexp_extract_all', 'regexp_split_to_array', 'regexp_split_to_table', 'string_split_regex', 'str_split_regex', 'regexp_escape'])), false)
UNION ALL
SELECT 'sql_pattern_functions__tooling' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_functions, ['regexp_matches', 'regexp_full_match', 'regexp_replace', 'regexp_extract', 'regexp_extract_all', 'regexp_split_to_array', 'regexp_split_to_table', 'string_split_regex', 'str_split_regex', 'regexp_escape'])), false)
UNION ALL
SELECT 'sql_printf' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name IN ('printf', 'format') AND len(list_filter(['%s', '{}'], pattern -> contains(f.literals[1], pattern))) > 0)) > 0), false)
UNION ALL
SELECT 'sql_qualify' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_qualify AND NOT list_contains(sql_functions, 'row_number')), false)
UNION ALL
SELECT 'sql_query_constant' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_table_function_calls, t -> t.name IN ('query', 'query_table') AND list_contains(t.args, 'constant'))) > 0), false)
UNION ALL
SELECT 'sql_read_auto' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_table_functions, ['read_json_auto', 'read_csv_auto', 'read_ndjson_auto'])), false)
UNION ALL
SELECT 'sql_read_text_pipe' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_table_function_calls, t -> t.name = 'read_text' AND len(list_filter(t.literals, l -> ends_with(rtrim(l), '|'))) > 0)) > 0), false)
UNION ALL
SELECT 'sql_reads_sql_file_as_text' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_table_function_calls, t -> t.name IN ('read_text', 'read_lines') AND len(list_filter(t.literals, l -> substr(parse_filename(l), length(parse_filename(l, true)) + 1) = '.sql')) > 0)) > 0 AND list_has_any(sql_functions, ['selfdispatch', 'quackapi_post', 'http_post', 'http_post_form', 'json_object'])), false)
UNION ALL
SELECT 'sql_recursive_cte' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_recursive_cte), false)
UNION ALL
SELECT 'sql_recursive_glob' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_table_function_calls, t -> t.name IN ('read_lines', 'read_text', 'read_blob') AND len(list_filter(t.literals, l -> list_contains(parse_path(l), '**'))) > 0)) > 0), false)
UNION ALL
SELECT 'sql_row_constructor' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_values_clause), false)
UNION ALL
SELECT 'sql_row_number_pick' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_qualify AND list_contains(sql_functions, 'row_number')), false)
UNION ALL
SELECT 'sql_scalar_subquery_select' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_scalar_subquery_in_select), false)
UNION ALL
SELECT 'sql_set_on_dev' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_sources, 'tool') AND list_contains(sql_verbs, 'SET') AND NOT list_contains([h[1:2] FOR h IN sql_heads], ['SET', 'VARIABLE'])), false)
UNION ALL
SELECT 'sql_shellfs_curl_self' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_shellfs_pipe_words, 'curl') AND len(list_filter(sql_shellfs_pipe_words, w -> contains(w, ':9495'))) > 0), false)
UNION ALL
SELECT 'sql_shellfs_exit_hack' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_table_function_calls, t -> len(list_filter(t.literals, l -> ends_with(rtrim(l), '|') AND len(list_filter(['|| true', '; true'], hack -> contains(l, hack))) > 0)) > 0)) > 0), false)
UNION ALL
SELECT 'sql_shellfs_grep' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_table_function_calls, t -> len(list_filter(t.literals, l -> list_has_any(string_split(translate(l, E'|;&\t\n', '     '), ' '), ['grep', 'egrep', 'rg']))) > 0)) > 0), false)
UNION ALL
SELECT 'sql_shellfs_nested_duckdb' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_shellfs_pipe_words, 'duckdb') AND list_has_any(sql_shellfs_pipe_words, ['-c', '.read'])), false)
UNION ALL
SELECT 'sql_shellfs_raw_pytest' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_table_function_calls, t -> t.name <> 'read_duck_hunt_log' AND len(list_filter(t.literals, l -> contains(l, 'pytest'))) > 0)) > 0), false)
UNION ALL
SELECT 'sql_shellfs_sleep' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_shellfs_pipe_words, 'sleep')), false)
UNION ALL
SELECT 'sql_shellfs_tail_head' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_shellfs_pipe_words, ['tail', 'head'])), false)
UNION ALL
SELECT 'sql_shellfs_text_munging' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_shellfs_pipe_words, ['sed', 'gsed', 'awk', 'gawk', 'tr', 'cut'])), false)
UNION ALL
SELECT 'sql_shellfs_timeout' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_shellfs_pipe_words, ['timeout', 'gtimeout'])), false)
UNION ALL
SELECT 'sql_star_count' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_has_count_star), false)
UNION ALL
SELECT 'sql_statement_too_long' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((sql_max_statement_lines > 80), false)
UNION ALL
SELECT 'sql_temp_object' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_heads, h -> h[1] = 'CREATE' AND list_has_any(h, ['TEMP', 'TEMPORARY']))) > 0), false)
UNION ALL
SELECT 'sql_tera_logic' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name = 'tera_render' AND len(list_filter(f.literals, l -> contains(l, '{%'))) > 0)) > 0), false)
UNION ALL
SELECT 'sql_tera_row_to_json' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_function_calls, f -> f.name = 'tera_render' AND list_contains(f.args, 'row_to_json'))) > 0), false)
UNION ALL
SELECT 'sql_text_join_function' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_functions, 'array_to_string')), false)
UNION ALL
SELECT 'sql_update_delete' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_has_any(sql_statement_kinds, ['update_statement', 'delete_statement'])), false)
UNION ALL
SELECT 'sql_url_build' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_functions, 'url_build')), false)
UNION ALL
SELECT 'sql_vague_cte_names' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(sql_cte_names, n -> CASE WHEN length(n) <= 2 THEN true ELSE n IN ('tmp', 'data', 'data2', 'kind', 'stuff', 'foo', 'temp') END)) > 0), false)
UNION ALL
SELECT 'sql_variable_get' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains(sql_functions, 'getvariable')), false)
UNION ALL
SELECT 'sql_variable_set' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains([h[1:2] FOR h IN sql_heads], ['SET', 'VARIABLE'])), false)
UNION ALL
SELECT 'sql_variable_set__config' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((list_contains([h[1:2] FOR h IN sql_heads], ['SET', 'VARIABLE'])), false)
UNION ALL
SELECT 'team_instructions_edit' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name IN ('Write', 'Edit') AND list_contains(file_path_parts, 'inframe') AND list_has_any(list_append(file_path_parts, file_name), ['skills', 'CLAUDE.md', 'AGENTS.md'])), false)
UNION ALL
SELECT 'uninstall_or_terraform' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((len(list_filter(bash_command_details, d -> CASE d.eff_exe WHEN 'terraform' THEN d.subcommand IN ('apply', 'destroy', 'import') ELSE d.subcommand = 'uninstall' END)) > 0), false)
UNION ALL
SELECT 'write_python_helper' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Write' AND file_ext = '.py' AND NOT list_has_all(file_path_parts, ['platform', 'backend'])), false)
UNION ALL
SELECT 'write_python_helper__dispatch' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Write' AND file_ext = '.py' AND NOT list_has_all(file_path_parts, ['platform', 'backend'])), false)
UNION ALL
SELECT 'write_python_helper__sql' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Write' AND file_ext = '.py' AND NOT list_has_all(file_path_parts, ['platform', 'backend'])), false)
UNION ALL
SELECT 'write_shell_script' AS check_id, call_id, tool_name, coalesce(next_prompt_corrects, false) AS corrected FROM facts WHERE coalesce((tool_name = 'Write' AND file_ext IN ('.sh', '.bash', '.zsh')), false);
