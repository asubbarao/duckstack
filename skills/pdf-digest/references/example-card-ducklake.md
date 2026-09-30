# DuckLake Documentation
_104 pp · 595.2800000000001×841.89pt · digest of 224 headings · `> lead sentence`, `# tf-idf terms`_

## Contents

  - DuckLake Documentation · p1 (pdf 1) · 0w
    - DuckLake version 1.0 Generated on 2026‑04‑21 at 07:18 UTC · p1 (pdf 1) · 0w
  - Contents · pi (pdf 2) · 32w
      - Summary 1 · pi (pdf 2) · 0w
      - Specification 3 · pi (pdf 2) · 10w
        # introduction, queries
      - DuckDB Extension 41 · pii (pdf 3) · 19w
        # features, guides, introduction, advanced
      - Acknowledgments 98 · piii (pdf 4) · 1w
- Summary · p1 (pdf 6) · 63w
  > This document contains DuckLake's documentation in a single‑file easy‑to‑search form
  # form, code, please, documentation, ducklake's, find
- Specification · p3 (pdf 8) · 8729w
  - Introduction · p4 (pdf 9) · 135w
    # specification, page, format, version
      - Building Blocks · p4 (pdf 9) · 124w
        # queries, requires, specification, uses
  - Data Types · p5 (pdf 10) · 1473w
    > DuckLake specifies multiple different data types for field values, and also supports nested types
    # field, specifies, column_type, nested, ducklake_column, multiple
      - Primitive Types · p5 (pdf 10) · 132w
        # precision, integer, signed, unsigned
      - Nested Types · p6 (pdf 11) · 81w
        # child, nested, collection, parent_column
      - Semi‑Structured Types · p6 (pdf 11) · 148w
        # variant, variants, shredded, primitive
      - Geometry Types · p6 (pdf 11) · 111w
        # geometry, collection, geometries, linestring
      - Type Encoding for Statistics · p7 (pdf 12) · 454w
        # special, statistics, string, min/max
      - Type Encoding for Data Inlining · p9 (pdf 14) · 519w
        # text, 2024-01-15, '2024-01-15, integer
  - Queries · p12 (pdf 17) · 1942w
    > This page explains the queries issued to the DuckLake catalog database for reading and writing data
    # issued, explains, writing, page, queries, reading
      - Reading Data · p12 (pdf 17) · 698w
        # referring, list, <snapshot_id>, need
      - Writing Data · p14 (pdf 19) · 1228w
        # identifier, referring, where, <table_id>
  - Tables · p21 (pdf 26) · 5178w
    - Tables · p21 (pdf 26) · 140w
      # describe, figure, v1.0, important
      - Snapshots · p22 (pdf 27) · 4w
        # ducklake_snapshot_changes, ducklake_snapshot
      - DuckLake Schema · p22 (pdf 27) · 9w
        # ducklake_view, ducklake_schema, ducklake_column, ducklake_table
      - Macros · p23 (pdf 28) · 6w
        # ducklake_macro_impl, ducklake_macro
      - Data Files and Tables · p23 (pdf 28) · 8w
        # ducklake_files_scheduled_for_deletion, ducklake_delete_file, ducklake_data_file
      - Data File Mapping · p23 (pdf 28) · 4w
        # ducklake_column_mapping
      - Statistics · p23 (pdf 28) · 18w
        # ducklake_file_column_stats, ducklake_file_variant_stats, ducklake_table_stats, ducklake_table_column_stats
      - Partitioning Information · p23 (pdf 28) · 11w
