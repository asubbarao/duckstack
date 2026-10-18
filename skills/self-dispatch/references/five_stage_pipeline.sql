-- Five dependent self-dispatch stages in one query: which community extensions did agents LOAD today, and how far is
-- each installed build behind upstream? Each stage is two CTEs: an atom (one rendered statement per row of the stage
-- before, array_agg(selfdispatch)) and a molecule (receipts unnested into JSON rows). A molecule's row is the next
-- atom's tera context directly, so templates read {{ extension }} with no extraction in between.
-- Verified on dev 2026-10-17: duck_hunt 9 commits behind, webbed 47 behind, http_client identical.
-- TRY_CAST drops a failed receipt (e.g. a build pinned to a tag the compare API rejects); select the receipts of a
-- stage to see its failures.
WITH transcripts AS (
    SELECT path FROM agent.entries
    WHERE reader = 'read_json' AND ext = '.jsonl' AND modified > current_localtimestamp() - INTERVAL 1 DAY
    ORDER BY modified DESC LIMIT 30
), stage1_dispatch AS (      -- atom: each transcript -> the extensions its agent LOADed (regex on log text)
    SELECT array_agg(selfdispatch(tera_render($t$
        SELECT DISTINCT unnest(regexp_extract_all(content, 'LOAD ([a-z_0-9]+)', 1)) AS extension
        FROM read_lines($cmd$tail -n 2000 '{{ path }}' |$cmd$) WHERE contains(content, 'LOAD ')
    $t$, transcripts::JSON, autoescape := false))) AS receipts
    FROM transcripts
), stage1_rows AS (          -- molecule
    SELECT DISTINCT row FROM stage1_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
), stage2_dispatch AS (      -- atom: each extension -> its installed community build
    SELECT array_agg(selfdispatch(tera_render($t$
        SELECT extension_name AS extension, extension_version AS installed_version
        FROM duckdb_extensions() WHERE extension_name = '{{ extension }}' AND installed_from = 'community'
    $t$, row, autoescape := false))) AS receipts
    FROM stage1_rows
), stage2_rows AS (
    SELECT row FROM stage2_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
), stage3_dispatch AS (      -- atom: each installed extension -> its repo (agents.ext_catalog keeps description.yml as JSON)
    SELECT array_agg(selfdispatch(tera_render($t$
        SELECT '{{ extension }}' AS extension, '{{ installed_version }}' AS installed_version, json_extract_string(yml, '$.repo.github') AS github
        FROM agents.ext_catalog WHERE extension_name = '{{ extension }}' AND github IS NOT NULL
    $t$, row, autoescape := false))) AS receipts
    FROM stage2_rows
), stage3_rows AS (
    SELECT row FROM stage3_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
), stage4_dispatch AS (      -- atom: each repo -> its upstream head commit
    SELECT array_agg(selfdispatch(tera_render($t$
        SELECT '{{ extension }}' AS extension, '{{ installed_version }}' AS installed_version,
               '{{ github }}' AS github, sha AS upstream_head
        FROM read_json($cmd$gh api 'repos/{{ github }}/commits?per_page=1' |$cmd$)
    $t$, row, autoescape := false))) AS receipts
    FROM stage3_rows
), stage4_rows AS (
    SELECT row FROM stage4_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
), stage5_dispatch AS (      -- atom: installed build vs upstream head
    SELECT array_agg(selfdispatch(tera_render($t$
        SELECT '{{ extension }}' AS extension, '{{ installed_version }}' AS installed_version,
               '{{ upstream_head }}' AS upstream_head, status, ahead_by
        FROM read_json($cmd$gh api 'repos/{{ github }}/compare/{{ installed_version }}...{{ upstream_head }}' |$cmd$)
    $t$, row, autoescape := false))) AS receipts
    FROM stage4_rows
)
SELECT receipt.status, receipt.body FROM stage5_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt);
