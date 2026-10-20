-- Definitions one inframe branch added, removed or modified since it left origin/staging. Git lists the changed files;
-- sitting_duck parses both ends of each. Name the branch in the first CTE. Three dependent self-dispatch stages:
-- merge base, changed files, file reads. Each stage keeps its row's keys with GROUP BY ALL.
-- A declaration wrapping a same-named definition (TS `const x` around its declarator) is dropped so each name counts
-- once, and the two ends join on qualified_name (scope path with per-name index), not on name.
-- Verified on dev 2026-10-19 for the INF-1661 branch: 19 changed files.
WITH declared AS (
    SELECT 'aloksubbarao/inf-1661-portal-customer-text-says-sub-and-vendor-instead-of' AS branch_name
), branch AS (
    SELECT declared.branch_name, ref.commit_hash
    FROM declared JOIN read_csv($c$git -C ~/inframe for-each-ref refs/heads --format='%(refname:short)%09%(objectname)' |$c$,
                                delim := E'\t', header := false, names := ['branch_name', 'commit_hash']) ref USING (branch_name)
), merge_base_dispatch AS (
    SELECT branch.*, array_agg(selfdispatch(tera_render($t$
        SELECT rtrim(content, E'\n') AS branch_point FROM read_lines($c$git -C ~/inframe merge-base origin/staging {{ commit_hash }} |$c$)
    $t$, branch::JSON, autoescape := false))) AS receipts
    FROM branch GROUP BY ALL
), branch_points AS (
    SELECT merge_base_dispatch.* EXCLUDE (receipts), e.row->>'branch_point' AS branch_point
    FROM merge_base_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
), name_status_dispatch AS (
    SELECT branch_points.*, array_agg(selfdispatch(tera_render($t$
        SELECT status_code, path, renamed_to
        FROM read_csv($c$git -C ~/inframe diff --name-status {{ branch_point }} {{ commit_hash }} |$c$,
                      delim := E'\t', header := false, null_padding := true, names := ['status_code', 'path', 'renamed_to'])
    $t$, branch_points::JSON, autoescape := false))) AS receipts
    FROM branch_points GROUP BY ALL
), changed_files AS (
    SELECT name_status_dispatch.* EXCLUDE (receipts), left(e.row->>'status_code', 1) AS status_code,
           coalesce(e.row->>'renamed_to', e.row->>'path') AS file_path, e.row->>'path' AS before_path
    FROM name_status_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
), file_sides AS (
    SELECT branch_name, file_path, 'before' AS side, git_uri(getenv('HOME') || '/inframe', before_path, branch_point) AS uri
    FROM changed_files WHERE status_code <> 'A' AND detect_language(file_path) IS NOT NULL
    UNION ALL
    SELECT branch_name, file_path, 'after', git_uri(getenv('HOME') || '/inframe', file_path, commit_hash)
    FROM changed_files WHERE status_code <> 'D' AND detect_language(file_path) IS NOT NULL
), read_batch AS (           -- one read_text over every side's blob; its filename column is the uri, the join key
    SELECT branch_name, array_agg(quote_literal(uri)) AS uri_literals FROM file_sides GROUP BY ALL
), read_dispatch AS (
    SELECT branch_name, array_agg(selfdispatch(tera_render($t$
        SELECT filename AS uri, content AS text FROM read_text([{{ uri_literals | join(sep=", ") }}])
    $t$, read_batch::JSON, autoescape := false))) AS receipts
    FROM read_batch GROUP BY ALL
), blobs AS (
    SELECT e.row->>'uri' AS uri, e.row->>'text' AS text
    FROM read_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
), nodes AS (
    SELECT branch_name, file_path, side, unnest(parse_ast_list(text, detect_language(file_path)), recursive := true)
    FROM file_sides JOIN blobs USING (uri)
), definitions AS (
    SELECT * FROM nodes WHERE is_definition(semantic_type) AND name <> ''
), wrapper_definitions AS (
    SELECT parent.branch_name, parent.file_path, parent.side, parent.node_id
    FROM definitions parent JOIN definitions child
      ON child.branch_name = parent.branch_name AND child.file_path = parent.file_path AND child.side = parent.side
     AND child.parent_id = parent.node_id AND child.name = parent.name
), own_definitions AS (
    SELECT * FROM definitions ANTI JOIN wrapper_definitions USING (branch_name, file_path, side, node_id)
), before_definitions AS (
    SELECT * FROM own_definitions WHERE side = 'before'
), after_definitions AS (
    SELECT * FROM own_definitions WHERE side = 'after'
)
SELECT coalesce(after_definitions.branch_name, before_definitions.branch_name) AS branch_name,
       coalesce(after_definitions.file_path, before_definitions.file_path) AS file_path,
       coalesce(after_definitions.qualified_name, before_definitions.qualified_name) AS qualified_name,
       coalesce(after_definitions.name, before_definitions.name) AS name,
       coalesce(after_definitions.type, before_definitions.type) AS node_type,
       CASE WHEN before_definitions.node_id IS NULL THEN 'added'
            WHEN after_definitions.node_id IS NULL THEN 'removed'
            WHEN after_definitions.descendant_count <> before_definitions.descendant_count THEN 'modified'
            WHEN after_definitions.peek <> before_definitions.peek THEN 'modified'
            ELSE 'unchanged' END AS change,
       before_definitions.start_line AS before_start_line, before_definitions.end_line AS before_end_line,
       after_definitions.start_line AS after_start_line, after_definitions.end_line AS after_end_line
FROM before_definitions FULL JOIN after_definitions
  ON after_definitions.branch_name = before_definitions.branch_name
 AND after_definitions.file_path = before_definitions.file_path
 AND after_definitions.qualified_name = before_definitions.qualified_name
WHERE change <> 'unchanged';
