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

`markdown`, `yaml`, `webbed` (html/xml) and `pdf` are community/unsigned extensions, not
autoloadable — they must be `LOAD`ed before `CREATE MACRO` even binds, and `pdf` (this
machine's own unsigned build, `asubbarao/duckdb-pdf`) additionally needs the CLI started
with `-unsigned`. Both are required unconditionally, even to read a `.csv`, because the
macro binds every branch's functions at creation time regardless of which `CASE` arm runs.

```bash
duckdb -unsigned -csv -c "
LOAD markdown; LOAD yaml; LOAD webbed; LOAD pdf;
CREATE OR REPLACE MACRO read_any(file_name) AS TABLE
  WITH json_case AS (FROM read_json_auto(file_name))
     , csv_case AS (FROM read_csv(file_name))
     , parquet_case AS (FROM read_parquet(file_name))
     , avro_case AS (FROM read_avro(file_name))
     , blob_case AS (FROM read_blob(file_name))
     , spatial_case AS (FROM st_read(file_name))
     , excel_case AS (FROM read_xlsx(file_name))
     , sqlite_case AS (FROM sqlite_scan(file_name, (SELECT name FROM sqlite_master(file_name) LIMIT 1)))
     -- read_text(files) -- no named parameters; returns filename, content, size, last_modified.
     -- Prose lives here, not in csv_case, so it is not parsed as delimited data.
     , text_case AS (FROM read_text(file_name))
     -- read_markdown(files, filename := false, content_as_varchar := false,
     --   maximum_file_size := 16777216, extract_metadata := true, normalize_content := true,
     --   extract_extensions := NULL). Two more named params exist on this build (flavor,
     --   include_stats) with no documented default in the extension's own README.
     , markdown_case AS (FROM read_markdown(file_name))
     -- read_yaml(files, auto_detect := true, multi_document := true,
     --   expand_root_sequence := true, ignore_errors := false,
     --   maximum_object_size := 16777216, sample_size := 20480,
     --   maximum_sample_files := 32, columns := NULL). Five more named params exist on
     --   this build (records, list_column_name, frontmatter_as_columns, maximum_file_size,
     --   strip_document_suffixes) with no documented default in the extension's own README.
     , yaml_case AS (FROM read_yaml(file_name))
     -- read_html(pattern, ignore_errors := false, maximum_file_size := 1048576,
     --   filename := false, columns := NULL, root_element := NULL, record_element := NULL,
     --   force_list := [], auto_detect := true, max_depth := 10, unnest_as := 'struct',
     --   all_varchar := false, datetime_format := 'auto', nullstr := NULL,
     --   attr_mode := 'prefix', attr_prefix := '@', text_key := '#text',
     --   empty_elements := 'object', namespaces := 'strip', union_by_name := false,
     --   sample_files := 8). No streaming param -- SAX-based streaming does not apply to HTML.
     , html_case AS (FROM read_html(file_name))
     -- read_xml(pattern, ...same named params and defaults as read_html above...,
     --   streaming := true).
     , xml_case AS (FROM read_xml(file_name))
     -- read_pdf(files, layout := 'reading', parse_tables := false, first_page := NULL,
     --   last_page := NULL, password := NULL, ignore_errors := false, ocr := false,
     --   auto_ocr := false, ocr_language/ocr_dpi/ocr_psm/ocr_oem/ocr_preprocess/
     --   ocr_retry/tessdata_dir/ocr_backend/ocr_plugin/ocr_endpoint := defaults).
     --   layout := 'physical' is passed explicitly (verified 2026-09-18, skills/pdf): the
     --   'reading' default flattens table/column alignment for prose and grids.
     , pdf_case AS (FROM read_pdf(file_name, layout := 'physical'))
     , ipynb_case AS (
         WITH nb AS (FROM read_json_auto(file_name))
         SELECT cell_idx, cell.cell_type,
                array_to_string(cell.source, '') AS source,
                cell.execution_count
         FROM nb, UNNEST(cells) WITH ORDINALITY AS t(cell, cell_idx)
         ORDER BY cell_idx
     )
  FROM query_table(
    CASE
      WHEN file_name ILIKE '%.json' OR file_name ILIKE '%.jsonl' OR file_name ILIKE '%.ndjson' OR file_name ILIKE '%.geojson' OR file_name ILIKE '%.geojsonl' OR file_name ILIKE '%.har' THEN 'json_case'
      WHEN file_name ILIKE '%.csv' OR file_name ILIKE '%.tsv' OR file_name ILIKE '%.tab' THEN 'csv_case'
      WHEN file_name ILIKE '%.txt' THEN 'text_case'
      WHEN file_name ILIKE '%.md' OR file_name ILIKE '%.markdown' THEN 'markdown_case'
      WHEN file_name ILIKE '%.yaml' OR file_name ILIKE '%.yml' THEN 'yaml_case'
      WHEN file_name ILIKE '%.html' OR file_name ILIKE '%.htm' THEN 'html_case'
      WHEN file_name ILIKE '%.xml' THEN 'xml_case'
      WHEN file_name ILIKE '%.pdf' THEN 'pdf_case'
      WHEN file_name ILIKE '%.parquet' OR file_name ILIKE '%.pq' THEN 'parquet_case'
      WHEN file_name ILIKE '%.avro' THEN 'avro_case'
      WHEN file_name ILIKE '%.xlsx' OR file_name ILIKE '%.xls' THEN 'excel_case'
      WHEN file_name ILIKE '%.shp' OR file_name ILIKE '%.gpkg' OR file_name ILIKE '%.fgb' OR file_name ILIKE '%.kml' THEN 'spatial_case'
      WHEN file_name ILIKE '%.ipynb' THEN 'ipynb_case'
      WHEN file_name ILIKE '%.db' OR file_name ILIKE '%.sqlite' OR file_name ILIKE '%.sqlite3' THEN 'sqlite_case'
      ELSE 'blob_case'
    END
  );

DESCRIBE FROM read_any('RESOLVED_PATH');
SELECT count(*) AS row_count FROM read_any('RESOLVED_PATH');
FROM read_any('RESOLVED_PATH') LIMIT 20;
"
```

**If this fails:**
- **`duckdb: command not found`** → invoke `/duckstack:install-duckdb` and retry.
- **Extension signature error on `pdf`** → the CLI must be started with `-unsigned` (this
  machine's `pdf` build, `asubbarao/duckdb-pdf`, is not signed); confirm the flag is present.
- **Missing extension** (e.g. spatial files, xlsx, sqlite) → retry with `INSTALL spatial; LOAD spatial;` or `INSTALL sqlite_scanner; LOAD sqlite_scanner;` prepended before the macro.
- **Wrong reader / parse error** → use the correct `read_*` function directly instead of `read_any`.

## Step 2 — Answer

Using the schema, row count, and sample rows, answer:

`${1:-describe the data: summarize column types, row count, and any notable patterns.}`
