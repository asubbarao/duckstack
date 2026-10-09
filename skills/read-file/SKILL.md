---
name: read-file
description: >
  Read any data file (CSV, JSON, Parquet, Avro, Excel, spatial, SQLite, Markdown, YAML,
  HTML, XML, PDF) or remote URL (S3, HTTPS). For deeper PDF work (multiple grains, OCR,
  forms, redaction, writing) use /duckstack:pdf instead.
  Use when user references a data file, asks "what's in this file", or wants to preview/profile a dataset.
  Not for source code.
argument-hint: <filename or URL> [question about the data]
allowed-tools: Bash
---

You are helping the user read and analyze a data file using DuckDB.

Filename given: `$0`
Question: `${1:-describe the data}`

## Step 1 — Read it

`RESOLVED_PATH` is `$0`. If the user gave a bare filename (no `/`), resolve it to a full path with `find` first.

Run a single DuckDB command that defines the `read_any` macro inline and reads the file.

For **remote files**, prepend the necessary LOAD/SECRET before the macro:

| Protocol | Prepend |
|---|---|
| `https://` / `http://` | `LOAD httpfs;` |
| `s3://` | `LOAD httpfs; CREATE SECRET (TYPE S3, PROVIDER credential_chain);` |
| `gs://` / `gcs://` | `LOAD httpfs; CREATE SECRET (TYPE GCS, PROVIDER credential_chain);` |
| `az://` / `azure://` / `abfss://` | `LOAD httpfs; LOAD azure; CREATE SECRET (TYPE AZURE, PROVIDER credential_chain);` |

For **local files**, no prefix needed.

Pick the reader from the extension and call it directly; nothing is wrapped in a macro.

| Extension | Reader |
|---|---|
| `.json` `.jsonl` `.ndjson` `.geojson` `.har` | `read_json` |
| `.csv` `.tsv` `.tab` | `read_csv` |
| `.parquet` `.pq` | `read_parquet` |
| `.avro` | `read_avro` |
| `.xlsx` `.xls` | `read_xlsx` (`LOAD excel`) |
| `.shp` `.gpkg` `.fgb` `.kml` | `st_read` (`LOAD spatial`) |
| `.db` `.sqlite` `.sqlite3` | `ATTACH '<path>' (TYPE sqlite, READ_ONLY)` then `SHOW ALL TABLES` |
| `.md` `.markdown` | `read_markdown` (`LOAD markdown`) |
| `.yaml` `.yml` | `read_yaml` (`LOAD yaml`) |
| `.html` `.htm` / `.xml` | `read_html` / `read_xml` (`LOAD webbed`) |
| `.pdf` | `read_pdf` (`LOAD pdf`; `/duckstack:pdf` for anything beyond text) |
| `.ipynb` | `read_json`, then `UNNEST(cells)` |
| `.txt`, anything else | `read_text`, or `read_blob` for binary |

```bash
duckdb :memory: -csv -c "
DESCRIBE FROM read_csv('RESOLVED_PATH');
SUMMARIZE FROM read_csv('RESOLVED_PATH');
FROM read_csv('RESOLVED_PATH') LIMIT 20;
"
```


`read_json` and `read_csv` already auto-detect by default; do not add the legacy
`_auto` spelling. For their complete installed named-parameter lists, defaults
worth remembering, ShellFS examples, and `encodings` versus ICU guidance, read
`~/duckdb-skills/skills/tera/references/shell_readers.sql`.

**If this fails:**
- **`duckdb: command not found`** → invoke `/duckstack:install-duckdb` and retry.
- **Extension signature error on `pdf`** → the CLI must be started with `-unsigned` (this
  machine's `pdf` build, `asubbarao/duckdb-pdf`, is not signed); confirm the flag is present.
- **Missing extension** → `INSTALL <ext> FROM community; LOAD <ext>;` (or plain `INSTALL spatial;` for core ones) and retry.
- **Parse error** → read the error; pass the reader's named parameters (delimiter, columns, format) explicitly.

## Step 2 — Answer

Using the schema, row count, and sample rows, answer:

`${1:-describe the data: summarize column types, row count, and any notable patterns.}`
