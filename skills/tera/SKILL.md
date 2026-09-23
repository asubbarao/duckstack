---
name: tera
description: >
  The tera template engine inside DuckDB — tera_render(template, context JSON, autoescape :=)
  — as the one way this user's .sql files write text: generated .sql that is then .read,
  RESULTS.md assembled from COPY … (FORMAT markdown) tables, and self-contained HTML pages.
  Covers the two signatures, building the context (struct literal, to_json, list(t),
  json_group_object), the COPY-to-file form, the template syntax that works in this build and
  the parts that do not (no file loader, so no include/extends/import; no date, urlencode,
  slugify or filesizeformat; no `//`; filters bind looser than arithmetic; `escape` throws on
  non-strings), how to read and bisect its errors, and when minijinja is the better engine.
  Use when writing or debugging a tera_render call or a .tera template, when a .sql must
  generate another .sql, or when an agent is about to reach for a .sh, Python or string
  concatenation to produce text. The page recipe on top of this is /duckstack:one-pager.
argument-hint: "[template path or the error text]"
allowed-tools: Bash
---

Read `/duckstack:duck` first; its process rules apply to everything that feeds a template.
This skill is the **engine reference**. The recipe for a shareable HTML report (granica memo
style, quickjs charts, the Verdict / tiles / scoreboard blocks) is `/duckstack:one-pager` —
it assumes what is here and does not repeat it.

A tera error is the template's fault or the context's, not tera's. Every claim below was run
in `duckdb :memory:` with `SET extension_directory='/Users/aloksubbarao/.duck/extensions'; LOAD tera;`.

## Verified facts (2026-09-22, DuckDB 1.5.5, tera 704c3cb, minijinja a4e836b, markdown loaded for `FORMAT markdown`)

| Fact | Evidence |
|---|---|
| Two overloads: `tera_render(template VARCHAR)` and `tera_render(template VARCHAR, context JSON)`, both → `VARCHAR`; named `autoescape := true\|false` | `duckdb_functions()`; the ext catalog lists the same two |
| `autoescape` defaults to **true**: `{{ v }}` with `<b>&</b>` renders `&lt;b&gt;&amp;&lt;&#x2F;b&gt;` | run |
| The **one-argument form ignores `autoescape := false`** — `tera_render('{{ "<b>" }}', autoescape := false)` still escapes. Pass `'{}'` as the context to turn escaping off | run |
| Context may be a JSON string, `{…}::JSON`, `to_json({…})`, or a bare struct (implicit cast) | all four rendered |
| A context that is not an object (`'[1,2]'`) → `Variable \`v\` not found` | run |
| NULL template or NULL context → NULL, no error | run |
| A missing variable is an error (`Variable \`x\` not found in context`); a JSON `null` value renders as the empty string | run |
| No file loader: `{% include %}`, `{% extends %}` and `{% import %}` fail (`Template '[other.html]' not found`, `… isn't loaded`, `… isn't present in Tera`). Inline `{% macro %}` works, called as `self::name(arg=…)` | run |
| Built without tera's `builtins` feature: filters `date`, `filesizeformat`, `urlencode`, `urlencode_strict`, `slugify` and the function `now()` are **not found** | run |
| No `//` (floor division): parse error at the second `/` | run |
| Whitespace control **works**: `{%- … -%}`, `{{- … -}}` | run (`a\n  {%- if true -%}\n  b` → `ab`) |
| Filters bind **looser** than arithmetic: `{{ a / 12 \| round }}` is `round(a / 12)`; `{{ b - a \| abs }}` is `abs(b - a)`; `{{ 10 * l \| length }}` errors (`l` used in a math operation) | run |
| A parenthesised filter cannot be used in arithmetic: `{{ (l \| length) * 10 }}`, `{{ a / (l \| length) }}`, `{% if (x \| round) > 3 %}` are parse errors. Arithmetic **after** a filter is fine: `{{ l \| length * 10 }}` → 20 | run |
| `escape` throws on anything not a string: `got \`null\`` and `got \`3\` but expected a String`. `autoescape := true` on the same values is fine (null → empty) | run |
| `{{ a / 0 }}` renders `NaN`, no error | run |
| `COPY (SELECT tera_render(…)) TO 'f' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '')` writes the string byte for byte plus one trailing newline | md5 of the file = md5(render ‖ `\n`) |
| `FORMAT csv, HEADER false` without `QUOTE ''` wraps the page in `"…"` and doubles every `"` | run |
| `COPY … (FORMAT markdown)` needs the `markdown` extension loaded (`Copy Function with name markdown does not exist`) | run |
| Render → `COPY` to `_x.sql` → `.read _x.sql` runs the generated statements | run |
| `{{ __tera_context }}` dumps the whole context as pretty JSON | run |

## 1. The call

```sql
-- tera_render(template VARCHAR)                                   -- autoescape always on
-- tera_render(template VARCHAR, context JSON, autoescape := true)  -- context must be a JSON object
SELECT tera_render('Hello {{ name }}!', {name: 'World'}::JSON);                          -- Hello World!
SELECT tera_render('{{ v }}', {v: '<b>'}::JSON, autoescape := false);                    -- <b>
SELECT tera_render('{{ v | safe }}', {v: '<b>'}::JSON);                                  -- <b>, per value
```

**autoescape.** Everything in this user's repos passes `autoescape := false`: the output is
SQL or Markdown (escaping would corrupt it) or HTML whose values were made safe in SQL. Leave
it on only when rendering untrusted text into HTML and you want every value escaped.

## 2. The context — build it in SQL, keep the template dumb

The context is one JSON object. Build it as a struct literal; each field is a scalar, a
struct, or a subquery. The idioms, all verified:

```sql
-- list(t) -> LIST(STRUCT)          : a whole view, one struct per row, for {% for r in rows %}
-- to_json(any) -> JSON             : the same thing as an explicit cast
-- json_group_object(key, value)    : one object keyed by a column, for {{ tables.rec_trade }}
-- parse_filename(path, trim_extension := false, separator := 'system')
-- read_text(source) -> filename, content, size, last_modified
SET VARIABLE ctx = {
  generated: strftime(now(), '%Y-%m-%d %H:%M UTC'),
  rows:      (SELECT list(t ORDER BY n) FROM page_rows t),
  pick:      (SELECT {name: name, url: url} FROM page_rows ORDER BY n LIMIT 1),
  tables:    (SELECT json_group_object(parse_filename(filename, true), content)
              FROM read_text('analysis/rec_*.md'))
}::JSON;
```

`json_merge_patch(getvariable('ctx'), {more: …}::JSON)` adds fields to an existing context
(granica `run.sql`). Never alias a context field or a view with an existing table's name —
see `/duckstack:one-pager` §4.

Everything the template prints is **finished in SQL**: durations
(`printf('%dm %02ds', s // 60, s % 60)`), pixel widths (`v * 420 // top`), percentages,
labels, and `coalesce(x, '')` for any value a filter will touch. That rule is what the
failures below come down to.

## 3. Writing the output — COPY to a file

```sql
-- COPY (query) TO 'path' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '')
--   HEADER  default true  -> false: no column-name line
--   QUOTE   default '"'   -> '': never wrap the value, never double its quotes
--   ESCAPE  default '"'   -> '': no escape char; redundant once QUOTE is '' on 1.5.5, kept so nothing is ever escaped
--   DELIMITER default ',' -> irrelevant: one column, so no delimiter is written
COPY (SELECT tera_render($tpl$…$tpl$, getvariable('ctx'), autoescape := false))
  TO 'page.html' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
```

The file is the rendered string followed by one newline. There is no `FORMAT text` in 1.5.5.
Put the template inline as a `$tpl$ … $tpl$` dollar-quoted string (slow.sql) or next to the
`.sql` as a `.tera` file read with `(SELECT content FROM read_text('tera/x.tera'))` (granica).

## 4. The three uses in Alok's repos

**Generate SQL, then run it** — `takehome-granica/run.sql`. Tera does the looping a table
function's literal-only arguments cannot; the generated file is ordinary SQL on disk.

```sql
-- tera/q.sql.tera:
--   {% for l in layouts %}
--   CREATE OR REPLACE TABLE t_{{ l.name }} AS SELECT {{ l.n }} AS n, '{{ l.name }}' AS name;
--   {% endfor %}
--   CREATE OR REPLACE VIEW all_t AS
--   {% for l in layouts %}SELECT * FROM t_{{ l.name }}{% if not loop.last %} UNION ALL BY NAME
--   {% endif %}{% endfor %};
SET VARIABLE ctx = {layouts: (SELECT list({name: name, n: n} ORDER BY n) FROM layouts)}::JSON;
COPY (SELECT tera_render((SELECT content FROM read_text('tera/q.sql.tera')), getvariable('ctx'), autoescape := false))
  TO '_q.sql' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
.read _q.sql
```

Verified: `_q.sql` held two `CREATE TABLE`s and the `UNION ALL BY NAME` view, and `.read`
created them. `.read` is a CLI dot-command: this works in `duckdb -f` / `-c ".read run.sql"`,
not through `quack_query` or the MCP `sql` tool. When the rendered SQL must run on the server,
see `/duckstack:self-dispatch`.

**Assemble RESULTS.md from tables** — `takehome-granica/tera/recommend.sql` +
`tera/results.md.tera`. Every number in the prose is a table first.

```sql
LOAD markdown;                                   -- registers COPY … (FORMAT markdown)
COPY (FROM rec_trade ORDER BY n) TO 'analysis/rec_trade.md' (FORMAT markdown);
SET VARIABLE report_ctx = {tables: (SELECT json_group_object(parse_filename(filename, true), content)
                                   FROM read_text('analysis/rec_*.md'))}::JSON;
-- results.md.tera:  {{ tables.rec_trade }}
--                   {{ tables.rec_missing | default(value="_(rec_missing not generated in this run)_") }}
COPY (SELECT tera_render((SELECT content FROM read_text('tera/results.md.tera')), getvariable('report_ctx'), autoescape := false))
  TO 'RESULTS.md' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
```

Verified: the markdown table rendered in place and the missing key fell through to the
`default`. `default` catches a missing key, not only null.

**Render an HTML page** — `~/inframe/internal/ci/duckdb/slow.sql` (§7 Render). One
`SET VARIABLE ctx = {…}::JSON` with a `list({…} ORDER BY …)` per table the page shows and
precomputed strings for every duration, then the whole page inline as `$tpl$<!doctype html>
… </html>$tpl$` into `COPY … TO 'slow.html'`. The page design is `/duckstack:one-pager`.

## 5. Template syntax that works in this build

```
{{ x }}  {{ r.name }}  {{ rows.0.name }}  {{ rows[1].k }}  {{ m["a"] }}  {{ "x" ~ i }}
{% for r in rows %} … {{ loop.index0 }} {{ loop.index }} {% if loop.first %}…{% endif %}{% if not loop.last %}, {% endif %} {% endfor %}
{% for k, v in obj %} … {% endfor %}                      -- iterate an object
{% if a > 5 and "x" in l %} … {% elif … %} … {% else %} … {% endif %}
{% set x = i * 3 %}   {# comment #}   {% raw %}{{ kept }}{% endraw %}   {% filter upper %}…{% endfilter %}
{% macro row(r) %}<td>{{ r.a }}</td>{% endmacro row %}{% for r in rows %}{{ self::row(r=r) }}{% endfor %}
{%- trim left   … trim right -%}                          -- whitespace control works
+ - * / %   ==  !=  <  >  and  or  not  in  is odd  is containing("a")  is starting_with("x")
range(end=3)   get_env(name="HOME", default="d")   throw(message="…")
```

Filters, each run on 2026-09-22 (all argument names are required keywords):

| Works | Example → result |
|---|---|
| `length` | `l \| length` → 3; also on strings |
| `truncate(length=, end="…")` | `s \| truncate(length=5)` → `Hello…` |
| `replace(from=, to=)`, `split(pat=)`, `first`, `last`, `nth(n=)`, `join(sep=)` | `s \| split(pat="/") \| last` → `x` |
| `default(value=)` | missing key or null → the value; `""` stays `""` |
| `lower`, `upper`, `title`, `capitalize`, `trim`, `striptags`, `wordcount` | |
| `round`, `round(precision=2)`, `round(method="floor"\|"ceil")`, `abs`, `int`, `float` | `3.14159 \| round(precision=2)` → 3.14 |
| `sort`, `sort(attribute=)`, `reverse`, `unique`, `slice(end=)`, `concat(with=)` | |
| `map(attribute=)`, `filter(attribute=, value=)`, `group_by(attribute=)`, `get(key=)` | `rs \| map(attribute="v") \| join(sep=",")` → `1,2,3` |
| `json_encode()`, `json_encode(pretty=true)`, `as_str`, `safe`, `escape_xml`, `pluralize` | |
| `escape` | strings only — see §6 |

| Missing (Filter/Function '…' not found) | Do it in SQL instead |
|---|---|
| `date`, `now()` | `strftime(ts, '%Y-%m-%d')` in the context |
| `filesizeformat` | `format_bytes(n)` |
| `urlencode`, `urlencode_strict` | `url_encode(s)` |
| `slugify`, `string` | `lower(replace(…))`, `x::VARCHAR` |

## 6. What fails, and the fix

| Symptom | Cause | Fix |
|---|---|---|
| parse error `expected an integer, a float…` at the second `/` | `//` does not exist | `s // 60` in SQL, pass the result |
| parse error `expected \`or\`, \`and\`, or a variable end` after `)` | `(x \| f) * n` — a parenthesised filter in arithmetic | put the filter last: `x \| length * n`, or compute in SQL |
| a number that is off by a filter, no error | filters bind looser than arithmetic: `100 * a / b \| round` rounds the product | compute in SQL; if kept, write the filter last on purpose |
| `Filter \`escape_html\` was called on an incorrect value: got \`null\`` (or a number) | `escape` on a non-string | `coalesce(x, '')` / `x::VARCHAR` in SQL, or escape in SQL and render with `autoescape := false` |
| `Variable \`x\` not found in context` | key missing, a typo, or the context is not an object | `{{ __tera_context }}` to see what arrived; `default(value=…)` if absence is legitimate |
| `Template '[x]' not found` / `isn't loaded` / `isn't present in Tera` | include / extends / import — no loader | inline the partial as a `{% macro %}`, or concatenate template strings in SQL |
| output in `"…"` with doubled quotes | COPY without `QUOTE ''` | the §3 form |
| `Copy Function with name markdown does not exist` | markdown not loaded | `LOAD markdown;` |

## 7. Reading and bisecting errors

Two kinds, and they read differently:

```
Failed to parse '__tera_one_off'          <- syntax; carries a position
Caused by:  --> 3:12                      <- line:col counted from the first character of the TEMPLATE
  |                                          (line 1 is the line $tpl$ opens on), not the .sql file
3 |   <p>{{ a // 2 }}</p>
  |            ^---

Failed to render '__tera_one_off'         <- data; no position, only the name
Caused by: Variable `rows.0.nope` not found in context …
```

`__tera_one_off` is the template's internal name for every call — it never names your file.

- **Parse error, position given.** For an inline `$tpl$`, the `.sql` line is (the line
  `$tpl$` opens on) + line − 1. An unclosed block (`{% for %}` with no `{% endfor %}`) points
  at the **end** of the template with `expected tag or some content` — search upward for the
  unclosed tag, not at the reported line.
- **Render error, no position.** The message names the variable or filter; search the
  template for it. If it is a filter on data, the value in the context is the problem: render
  `{{ __tera_context }}` with the same context and read the JSON.
- **Bisect** when the message is not enough: wrap the back half of the template in
  `{# … #}` and re-render; keep halving until it passes. Or shrink the context with
  `json_merge_patch(getvariable('ctx'), {rows: []}::JSON)` to tell a template bug from a data
  bug. Never patch the template until one of these has named the line or the value.

## 8. minijinja — the alternative engine

```sql
INSTALL minijinja FROM community; LOAD minijinja;
-- minijinja_render(template VARCHAR) -> VARCHAR                                   -- no context
-- minijinja_render_with_context(template VARCHAR, context JSON, autoescape := true) -> VARCHAR
SELECT minijinja_render_with_context('{{ i // 2 }} {{ (l | length) * 10 }} {{ "%dm %02ds" | format(125 // 60, 125 % 60) }}',
                                     {i: 7, l: [1, 2]}::JSON, autoescape := false);   -- 3 20 2m 05s
```

Verified 2026-09-22 against tera on the same inputs:

| | tera | minijinja |
|---|---|---|
| `//`, `(x \| f) * n` | parse errors | work |
| filter argument style | keywords: `join(sep=", ")`, `default(value="d")` | Jinja2 positional: `join(", ")`, `default("d")` |
| `truncate`, `json_encode` | yes | not found (`tojson` not found either) |
| `format` (printf) | no | `"%dm %02ds" \| format(a, b)` |
| undefined variable | error | renders empty; only `x.y` on an undefined `x` errors |
| `escape` on null / number | throws | `none` / `3` |
| include / extends / import, date, urlencode, filesizeformat | fail | fail |
| error text | `--> line:col` + caret | `Error { kind: SyntaxError, …, line: N }` plus the source excerpt |
| autoescape default | on | on |

Pick **tera** by default — it is what every existing template here is written in, and a
missing variable failing loudly is what you want in generated SQL. Pick **minijinja** when a
template is Jinja2 already (dbt-style macros, templates copied from Python projects) or when
it genuinely needs `//`, `format`, or arithmetic on a filtered value and precomputing in SQL
would be contortion. Do not mix engines in one file.
