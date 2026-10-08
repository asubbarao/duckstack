-- Render a three-transport Webbed inspector. Tera owns only repeated fetch
-- branches; SQL owns page parsing and result shaping in webbed_fetch.tera.
INSTALL tera FROM community;
LOAD tera;
INSTALL parser_tools FROM community;
LOAD parser_tools;

WITH template AS (
    SELECT content
    FROM read_text('/Users/aloksubbarao/duckdb-skills/templates/webbed_fetch.tera')
),
rendered AS (
    SELECT tera_render(
        content,
        json_object(
            'sources', [
                {
                    'source': 'crawler',
                    'kind': 'crawler',
                    'url': 'https://duck-tails.readthedocs.io/en/latest/',
                    'crawler_options': [
                        {'name': 'cache_ttl', 'value': '24'},
                        {'name': 'cache', 'value': 'false'},
                        {'name': 'follow', 'value': chr(39) || chr(39)},
                        {'name': 'extract', 'value': '[]::VARCHAR[]'},
                        {'name': 'max_depth', 'value': '1'},
                        {'name': 'respect_robots', 'value': 'true'},
                        {'name': 'workers', 'value': '1'},
                        {'name': 'batch_size', 'value': '1'},
                        {'name': 'max_results', 'value': '1'},
                        {'name': 'user_agent', 'value': chr(39) || 'InFrame webbed HTML sites reader/1.0' || chr(39)},
                        {'name': 'timeout', 'value': '30'},
                        {'name': 'state_table', 'value': chr(39) || chr(39)},
                        {'name': 'delay', 'value': '0'}
                    ]
                },
                {'source': 'http_client', 'kind': 'http_client', 'url': 'https://duck-tails.readthedocs.io/en/latest/'},
                {'source': 'shellfs_curl', 'kind': 'shellfs_curl', 'url': 'https://duck-tails.readthedocs.io/en/latest/', 'curl_flags': '-sS -L'}
            ]
        ),
        autoescape := false
    ) AS generated_sql
    FROM template
)
SELECT len(generated_sql)::BIGINT AS generated_sql_chars,
       is_parsable(generated_sql) AS generated_sql_parsable,
       left(generated_sql, 100) AS generated_sql_preview
FROM rendered;
