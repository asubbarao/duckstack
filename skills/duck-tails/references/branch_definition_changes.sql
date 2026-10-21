-- Definitions one inframe branch added, removed or modified since it left origin/staging. Git lists the changed files;
-- sitting_duck parses both ends of each. Run on dev, whose working directory is ~/inframe (server/setup.sql), so git
-- needs no -C; repo is only for the git:// uris, which read_text reports back absolute. Name the branch in the first CTE.
-- Three dependent self-dispatch stages (merge base, changed files, one read_text of every blob); each keeps its row's
-- keys with GROUP BY ALL and its sql beside the receipts. A failed dispatch at any stage stays a row: read_failed is
-- true and read_error carries the receipt's error, so a bad ref or blob is never silently missing. A declaration wrapping a same-named definition (TS `const x`
-- around its declarator) is dropped so each name counts once; the ends join on qualified_name, not on name.
-- Verified on dev 2026-10-19 for the INF-1661 branch: 19 changed files, 20 definitions, 3.8 s.
WITH declared AS (
    SELECT 'aloksubbarao/inf-1661-portal-customer-text-says-sub-and-vendor-instead-of' AS branch_name,
           getenv('HOME') || '/inframe' AS repo
), branch AS (
    SELECT declared.*, ref.commit_hash
    FROM declared JOIN read_csv($c$git for-each-ref refs/heads --format='%(refname:short)%09%(objectname)' |$c$,
                                delim := E'\t', header := false, names := ['branch_name', 'commit_hash']) ref USING (branch_name)
), merge_base_dispatch AS (
    SELECT *, array_agg(selfdispatch(sql)) AS receipts
    FROM (SELECT *, tera_render($t$SELECT rtrim(content, E'\n') AS branch_point FROM read_lines($c$git merge-base origin/staging {{ commit_hash }} |$c$)$t$,
                                branch::JSON, autoescape := false) AS sql
          FROM branch)
    GROUP BY ALL
), branch_points AS (
    SELECT merge_base_dispatch.* EXCLUDE (sql, receipts), e.row->>'branch_point' AS branch_point,
           receipt.error IS NOT NULL AS read_failed, receipt.error AS read_error
    FROM merge_base_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(coalesce(TRY_CAST(receipt.body AS JSON[]), [NULL::JSON])) AS e(row)
), name_status_dispatch AS (
    SELECT *, array_agg(selfdispatch(sql)) AS receipts
    FROM (SELECT *, tera_render($t$SELECT status_code, path, renamed_to FROM read_csv($c$git diff --name-status {{ branch_point }} {{ commit_hash }} |$c$,
                                   delim := E'\t', header := false, null_padding := true, names := ['status_code', 'path', 'renamed_to'])$t$,
                                branch_points::JSON, autoescape := false) AS sql
          FROM branch_points WHERE NOT read_failed)
    GROUP BY ALL
), changed_files AS (
    SELECT name_status_dispatch.* EXCLUDE (sql, receipts, read_failed, read_error), left(e.row->>'status_code', 1) AS status_code,
           e.row->>'path' AS before_path, coalesce(e.row->>'renamed_to', before_path) AS file_path,
           receipt.error IS NOT NULL AS read_failed, receipt.error AS read_error
    FROM name_status_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(coalesce(TRY_CAST(receipt.body AS JSON[]), [NULL::JSON])) AS e(row)
), file_sides AS (
    SELECT branch_name, file_path, s.side, git_uri(repo, s.path, s.rev) AS uri, detect_language(file_path) AS language
    FROM (FROM changed_files WHERE NOT read_failed)
    CROSS JOIN UNNEST(list_filter([{'side': 'before', 'path': before_path, 'rev': branch_point, 'absent_when': 'A'},
                                   {'side': 'after', 'path': file_path, 'rev': commit_hash, 'absent_when': 'D'}],
                                  s -> s.absent_when <> status_code)) AS t(s)
    WHERE language IS NOT NULL
), read_batch AS (           -- one read_text over every blob; its filename column is the uri, the join key
    SELECT branch_name, array_agg(quote_literal(uri)) AS uri_literals FROM file_sides GROUP BY ALL
), read_dispatch AS (
    SELECT *, array_agg(selfdispatch(sql)) AS receipts
    FROM (SELECT *, tera_render($t$SELECT filename AS uri, content AS text FROM read_text([{{ uri_literals | join(sep=", ") }}])$t$,
                                read_batch::JSON, autoescape := false) AS sql
          FROM read_batch)
    GROUP BY ALL
), blobs AS (
    SELECT branch_name, e.row->>'uri' AS uri, e.row->>'text' AS text,
           receipt.error IS NOT NULL AS read_failed, receipt.error AS read_error
    FROM read_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(coalesce(TRY_CAST(receipt.body AS JSON[]), [NULL::JSON])) AS e(row)
), failed_reads AS (         -- every failed dispatch, from any stage
    SELECT branch_name, 'merge-base' AS failed_stage, read_error FROM branch_points WHERE read_failed
    UNION ALL SELECT branch_name, 'diff --name-status', read_error FROM changed_files WHERE read_failed
    UNION ALL SELECT branch_name, 'read_text', read_error FROM blobs WHERE read_failed
), definitions AS (
    SELECT * FROM (SELECT branch_name, file_path, side, unnest(parse_ast_list(text, language), recursive := true)
                   FROM file_sides JOIN (SELECT uri, text FROM blobs WHERE NOT read_failed) AS blob USING (uri))
    WHERE is_definition(semantic_type) AND name <> ''
), own_definitions AS (      -- drop a definition whose child has its name
    SELECT * FROM definitions parent ANTI JOIN definitions child
      ON child.branch_name = parent.branch_name AND child.file_path = parent.file_path AND child.side = parent.side
     AND child.parent_id = parent.node_id AND child.name = parent.name
)
SELECT branch_name, file_path, qualified_name, coalesce(after.name, before.name) AS name, coalesce(after.type, before.type) AS node_type,
       CASE WHEN before.node_id IS NULL THEN 'added' WHEN after.node_id IS NULL THEN 'removed'
            WHEN after.descendant_count <> before.descendant_count THEN 'modified'
            WHEN after.peek <> before.peek THEN 'modified' ELSE 'unchanged' END AS change,
       before.start_line AS before_start_line, before.end_line AS before_end_line,
       after.start_line AS after_start_line, after.end_line AS after_end_line, false AS read_failed
FROM (FROM own_definitions WHERE side = 'before') AS before
FULL JOIN (FROM own_definitions WHERE side = 'after') AS after USING (branch_name, file_path, qualified_name)
WHERE change <> 'unchanged'
UNION ALL BY NAME
SELECT branch_name, 'read_failed' AS change, true AS read_failed, failed_stage, read_error FROM failed_reads;
