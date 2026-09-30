# Dev storage: measured 2026-09-28

`CREATE OR REPLACE TABLE` is not an append-only history and is not inherently a storage leak.
Keep the replacement query; distinguish database-file allocation, live blocks, and free blocks.

On DuckDB 1.5.5 (`d8cdaa33fd`), the 470,199,054,336-byte dev file reported
35,066,478,592 bytes used and 435,132,563,456 bytes free. A normal checkpoint changed
those to 3,720,347,648 bytes used and 466,478,694,400 bytes free without shrinking the file.
Live telemetry/startup blocks occupied its final block IDs, preventing tail truncation.

Bulk insertion can write row groups directly to the database while recording mostly pointers
in the WAL (`src/storage/local_storage.cpp:100-135` at the above source revision).
The configured 128 MiB WAL threshold is therefore not a database-file growth bound.
This explains the relevant reclamation mechanism, not every historical allocation in the file.

`setup.sql` schedules standalone `CHECKPOINT;` at second 30 of each minute. It can report a
busy-writer error; the next scheduled attempt retries without blocking new work. Do not put
`FORCE CHECKPOINT` inside a forwarded write batch: this installation was observed spinning
on the checkpoint lock and blocking new transactions. Separate MCP write/checkpoint calls
passed two full replacements with identical 468,108-row checksums and no file growth.

Keep registration column-driven over the missing-job relation. This build incorrectly marks
`cron` and `cron_delete` as having no side effects. A constant `cron(...) WHERE ...` registered
a duplicate even when it returned zero rows; `cron(query, schedule)` over `EXCEPT cron_jobs()`
did not. Registration no-op tests must inspect the jobs afterward, not just returned rows.

Compaction used `COPY FROM DATABASE` inside the existing central service, not another engine.
Before switching, all 85 tables passed bidirectional `EXCEPT ALL`; all 62 views and 106 macros
were retained. The only definition-text differences were reordered `EXCLUDE` name sets.
The first compact file was 3,272,093,696 bytes. A refresh may temporarily require old and new
blocks; do not claim that the compact baseline is a hard peak-storage limit.

After the full refresh passed, a second copy again passed exact comparisons for all 85 tables.
The final active database was 3,283,628,032 bytes. Both obsolete files (470,199,054,336 and
6,672,363,520 bytes) were removed after the central MCP restarted successfully. Filesystem
available space increased by 476,913,410,048 bytes across that deletion. All source SQL,
credentials, external history, and raw inputs were retained. The missing stopword seed file
was reconstructed from the preserved 524-row table and passed bidirectional comparison.
