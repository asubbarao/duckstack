# Temporary repaired reader

`com.inframe.agent-reader` runs one unsigned DuckDB in memory on authenticated
`quack:127.0.0.1:19494`. It loads the versioned artifact named in `agent_reader.sql`;
no unsigned extension is installed into the community extension directory.
`server/agent_reader.sql` is its complete SQL setup.

The signed main database on port 9495 reads it through `agent.conversations`.
The existing five-minute job replaces `agent.stream`, then updates BM25 and vector
indexes in the main database. No staging Parquet or second transcript database is needed.
`agent.reader_build` identifies the artifact serving the data. `agent_base.sql`, read
by setup, exposes the complete reader schema as `agent.conversations`, including
raw_event, metadata, tool inputs, usage, identities, relationships, and diagnostics.
The attached reader supports column projection, so callers select only what they need.
NULL remains NULL. Summaries and search are derived from this base; truncation belongs
in their presentation columns, never in the base view.

Check `cron_jobs()` for successful refreshes and compare `max(ts)` in `agent.stream`
with source event timestamps. An idle session's old last_ts does not mean ingestion is stale.
If the reader is unavailable, CTAS must fail without replacing the previous stream.

Once the upstream repair and community extension pin are merged and the signed binary
is published, upgrade agent_data from community and restart the main service to load it.
Replace the bridge view in `agent_base.sql` with the three native read_conversations
calls from `agent_reader.sql`, remove agent.reader_build, and rerun agent_stream_schedule.sql.
Verify the stream and indexes, then unload com.inframe.agent-reader and remove its plist.
This bridge is temporary deployment plumbing; parser fixes belong upstream.
