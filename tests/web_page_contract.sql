-- Run from the repository root through ShellFS. Requires native quackapi_fetch bounds/effective URL.
-- DUCKSTACK_QUACKAPI_EXTENSION may select a candidate artifact; dev remains the POST target on 9495.
-- Crawl: 30s, one worker, batch 1, no following, depth 0, no cache, one page per probe.
SELECT content FROM read_text($command$uv run --no-project --with duckdb==1.5.6 --with numpy python - <<'PY'
import duckdb, json, os
from pathlib import Path

connection = duckdb.connect(config={'allow_unsigned_extensions': True, 'threads': 4, 'memory_limit': '4GB',
                                  'extension_directory': str(Path.home() / '.duck/extensions')})
artifact = os.environ.get('DUCKSTACK_QUACKAPI_EXTENSION', 'quackapi')
connection.execute('LOAD ' + "'" + artifact.replace("'", "''") + "'")
for extension in ['httpfs', 'webbed', 'netquack', 'urlpattern']:
    connection.execute('LOAD ' + extension)
source = Path('server/macros.sql').read_text()
connection.execute(source)
version = connection.execute("SELECT version(), extension_version FROM duckdb_extensions() WHERE extension_name='quackapi'").fetchone()

def requests():
    return sum(dialed + reused for dialed, reused in connection.execute(
        "SELECT dialed, reused FROM quackapi_http_pool() WHERE host='http://127.0.0.1:9495'"
    ).fetchall())

program = '''WITH page_statements AS (
    SELECT id, CASE WHEN id % 2 = 0
                   THEN concat('SELECT ', id::VARCHAR, ' AS dispatch_probe') END AS executable_sql
    FROM range(50) AS source(id)
), page_posts AS (
    SELECT *, array_agg(selfdispatch(executable_sql)) AS arr FROM page_statements GROUP BY ALL
)
SELECT id, executable_sql, receipt.*
FROM page_posts CROSS JOIN UNNEST(arr) AS t(receipt) ORDER BY id'''
before = requests()
null_rows = connection.execute(program.replace('id % 2 = 0', 'false')).fetchall()
after_null = requests()
assert len(null_rows) == 50 and all(row[1:] == (None, None, None, None) for row in null_rows)
assert after_null == before
mixed_rows = connection.execute(program).fetchall()
after_mixed = requests()
assert len(mixed_rows) == 50
assert sum(row[2] == 200 and row[4] is None for row in mixed_rows) == 25
assert sum(row[1:] == (None, None, None, None) for row in mixed_rows) == 25
assert after_mixed - after_null == 25
assert connection.execute("SELECT quote_literal(NULL), quote_literal('')").fetchone() == (None, "''")

connection.execute("PRAGMA explain_output='all'")
query = "SELECT links FROM web_page('https://www.nflbite.is/')"
plans = dict(connection.execute('EXPLAIN ' + query).fetchall())
unused = ['duckblocks', 'images', 'tables', 'dom', 'attributes', 'document', 'resolved', 'urls', 'frames', 'raw_body', 'url_parts']
for column in unused:
    assert column in plans['logical_plan'], column
    assert column not in plans['logical_opt'], column
    assert column not in plans['physical_plan'], column
response_plan = dict(connection.execute("EXPLAIN SELECT response FROM web_page('https://www.nflbite.is/')").fetchall())
for column in unused + ['links', 'html']:
    assert column not in response_plan['logical_opt'], column
links = connection.execute(query).fetchone()[0]
assert links

# Instrument the actual expensive expressions: selecting links must never invoke their probes.
calls = []
def probe(name, body):
    calls.append(name)
    return True
connection.create_function('unused_parser_probe', probe, ['VARCHAR', 'VARCHAR'], 'BOOLEAN')
expressions = ['html_to_duck_blocks(html)', 'html_extract_images(html)', 'html_extract_tables_json(html)',
               'parse_html(html::VARCHAR)', "xml_extract_attributes(dom, '//*')", 'xml_to_json(dom)', 'extract_urls(body)']
instrumented = source
for expression in expressions:
    instrumented = instrumented.replace(expression, "(CASE WHEN unused_parser_probe('" + expression.replace("'", "''") + "', body) THEN " + expression + ' END)')
connection.execute(instrumented)
assert connection.execute(query).fetchone()[0]
assert calls == [], calls
connection.execute("SELECT * FROM web_page('https://www.nflbite.is/')").fetchall()
assert set(calls) == set(expressions), calls
print(json.dumps({'runtime': version, 'null_rows': len(null_rows), 'null_posts': after_null - before,
                  'mixed_rows': len(mixed_rows), 'mixed_posts': after_mixed - after_null,
                  'links': len(links), 'pruned_columns': unused, 'unused_parser_calls_for_links': 0,
                  'full_projection_probes': len(set(calls)), 'response_only_parsing_pruned': True}))
PY
|$command$);
