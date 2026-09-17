-- ============================================================================
-- <artifact name>.sql — <what it braids, e.g. crawler × webbed>. One artifact, run by path:
--   QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -f <artifact name>.sql
-- `-f` keeps ~/.duckdbrc (the resource floor); the token is env on the shell line, never a
-- literal here. Pinned: DuckDB v1.5.5 osx_arm64; quack c154811; <other extension revs>.
-- ============================================================================
LOAD quack;
-- ATTACH uri AS name (TYPE quack, TOKEN ...) -- spell quack:host:port, never quack://
ATTACH 'quack:localhost:9494' AS dev (TYPE quack, TOKEN getenv('QUACK_TOKEN'));

-- body: statements in dependency order, one table per statement, raw first; each runs on the
-- server inside dev.query($$ ... $$). Every function call carries a comment listing all its
-- parameters and defaults.

-- verification (comments, run by hand):
--   FROM dev.query($$FROM whoami()$$);                                  -- name=dev
--   FROM dev.query($$SELECT table_name, estimated_size FROM duckdb_tables() WHERE NOT internal$$);
