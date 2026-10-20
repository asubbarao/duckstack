# SQL manifesto

Data is the program. A reader who knows neither Tera nor self-dispatch should be able to say
what a query does by reading its first CTE. Everything after that is plumbing in plain view.

## 1. The first CTE says what is being done

The first CTE is a declaration: rows of intent, written as values. A command, its arguments,
its target and its verb are columns. Arrays hold argument lists, so a command line is data,
never a string assembled somewhere else.

```sql
WITH intent AS (
    SELECT 'W5 (5178)' AS window_title,
           'submit'    AS verb,
           ['/review INF-1554'] AS text
), ...
```

A shell pipe is two arrays, not a quoted line:

```sql
SELECT ['git', 'log', '--oneline', '-5'] AS cmd,
       ['jq', '-r', '.[].name']          AS then_cmd
```

A full string is fine when nothing needs to be rendered or manipulated.

## 2. Grammar is data

What a program can do lives in a relation you can SELECT: `osascript_verbs`, `shell_verbs`,
`seam_catalog`. Teaching the system a new action is a new row, not a new macro or code path.
Host state is a view: `terminal_windows`, `terminal_tabs`, `chrome_windows`, `chrome_tabs`.
Selecting the view reads the host; a verb view's row is its receipt.

## 3. Tera renders, SQL decides

Tera is a templating engine, not a place for logic. SQL owns selection, joins, filters, CASE,
ordering and every value. A template only substitutes columns and repeats syntax.

Templates are few and generic, kept in one folder and referenced by name:

| template | renders |
| -- | -- |
| `reader-shellfs` | `SELECT … FROM read_csv('<cmd> \|', <reader options>)` |
| `reader-plain` | `SELECT … FROM <reader>('<path>', <options>)` |
| `bash` | one command line from `cmd` and `args` arrays, piped stages joined |
| `osascript` | one AppleScript program, delivered as a quoted heredoc |

```sql
rendered AS (
    SELECT tera_render('reader-shellfs.tera', i::JSON,
                       autoescape := false,
                       template_path := '<templates>/*.tera') AS sql
    FROM intent AS i
)
```

The query should read almost like an ordinary query. Someone could replace Tera with plain
string construction without redesigning the program.

This reverses the older "tera at the tail, never upstream" rule (duckdb-ops-toolkit WRITEUP):
Tera now renders statements as well as artifacts, because a generic template reads better than
quote-building. Building SQL text from character codes, `printf` or `format` stays banned.

## 4. Self-dispatch is visible

The atom is an ordinary control relation: original source columns plus readable executable SQL.
Selecting it shows the generated programs without executing them. SQL owns every decision;
Tera only removes construction boilerplate. Keep those columns when collecting posts, then
unnest their array beside the same source row. Several preparation CTEs are fine; a fixed CTE
count is not the contract. Each subsequent atom reads the preceding results, so the dependency
graph can stay one query. SQL, ShellFS readers and network calls fit the same pattern without encoding.

Execution is always the same lines, in the query, never hidden in a bash loop, a template
or a macro tower:

```sql
dispatched AS (
    SELECT *, array_agg(selfdispatch(sql)) AS receipts FROM rendered GROUP BY ALL
)
SELECT source.* EXCLUDE(receipts), r.* FROM dispatched AS source CROSS JOIN UNNEST(receipts) AS t(r)
```

A single command still goes through `array_agg` and `CROSS JOIN UNNEST` of a one-element
array. Use `WITH ORDINALITY` when order matters; arrays alone don't establish execution order.
Keep the generated `sql` beside its receipt when anything downstream needs it.

## 5. Views and tables first, macros last

The upfront work is declarative: verb relations, host-state views, generic templates.
Macros are rare, proposed one at a time with name, parameters, body and what each replaces.
No construction macros, no dispatch macros, no `macro(macro(...))` towers. A new table needs
the same proposal; derived state is a view.

## 6. No logic outside SQL

No bash `for` loops, no `.sh` files, no Python in the data path, no `jq` doing what SQL could
do. When a tool must run, its command line comes from rows and its output comes back as rows
through a reader. Parse with readers and extension functions, never `split_part` surgery;
regex only on web pages and log lines.

## 7. Targets are located, never assumed

An action names its target by what it is (a window title, a tab URL, a session tty) and is
joined against the live host-state view before anything is sent. No match sends nothing.
Never send keystrokes to whatever window happens to be in front (System Events).

## 8. Parquet is a carry, not a home

Parquet files are temporary: a hand-off between runs, a snapshot to rebuild from. The living
state is the dev DuckDB, rebuilt from `setup.sql`. A light switch carries the database across a
restart: export every table to Parquet, wipe the database file, start clean, import the Parquet
back. It must be idempotent: running it twice, or after a crash halfway, ends in the same state,
and an import that fails leaves the export in place to retry.

## 9. Dev being down changes nothing

Dev is one endpoint, not a dependency. When it refuses a call, the same work runs in a local
`:memory:` client that `.read`s the boot files (`server/extensions.sql`, `server/macros.sql`,
`server/host.sql`), and the agent stream is read straight from its Parquet under
`~/.duck/lake/agent`. Flip the switch in the background; never wait on it or report it as a
blocker. A query that can take dev down is the defect: broad scans of the transcript store go per
session file through self-dispatch, or run locally. Anything a boot file creates must bind
without launching an app or failing, because `CREATE VIEW` runs the reader once to bind it.

## Where this came from

The ideas, not the code. `asubbarao/duckdb-chrome-bridge` and `asubbarao/duckdb-ops-toolkit`
(conduit) state the right principles: grammar is a table (`bridge_verbs`, `seam_catalog`),
construction is a view, "SELECTing the view IS the act; the row is the receipt", no
`macro(macro(...))` towers. Their SQL does not follow them: statements are glued together with
`replace()` and character codes, receipts are re-parsed with selectors, and macros multiply.
Read them for the ideas and treat their SQL as the counter-example. The point is to write it
properly.
