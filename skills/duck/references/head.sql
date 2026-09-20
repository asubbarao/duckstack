-- ============================================================================
-- <artifact name>.sql — <what it braids, e.g. crawler × webbed>. One artifact, run by path:
--   QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -f <artifact name>.sql
-- `-f` keeps ~/.duckdbrc (the resource floor); the token is env on the shell line, never a
-- literal here. Pinned: DuckDB v1.5.5 osx_arm64; quack c154811; <other extension revs>.
-- ============================================================================
LOAD quack;

-- body: statements in dependency order, one table per statement, raw first. Each runs on the
-- server inside a quack_query body, written as if you were sitting on the server -- tables
-- unqualified, joins and CREATE OR REPLACE TABLE all normal. Every function call carries a
-- comment listing all its parameters and defaults.
--
-- quack_query(uri, sql, disable_ssl := false, token := ...) -> the server's result as rows
--   spell it quack:host:port, never quack://
--   no ATTACH: it does not connect on DuckDB 1.5.5 (duckdb-quack#132) and was the weaker
--   form before that -- see /duckstack:quack
FROM quack_query('quack:localhost:9494', $$
  <one complete body>
$$, token := getenv('QUACK_TOKEN'));

-- verification (comments, run by hand):
--   FROM quack_query('quack:localhost:9494', $$FROM whoami()$$, token := getenv('QUACK_TOKEN'));
--     -- name=dev
--   FROM quack_query('quack:localhost:9494',
--     $$SELECT table_name, estimated_size FROM duckdb_tables() WHERE NOT internal$$,
--     token := getenv('QUACK_TOKEN'));
