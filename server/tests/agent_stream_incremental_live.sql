-- Execute the saved incremental program through the selected dev Quack service.
LOAD quack;
SET VARIABLE stream_program = (SELECT content FROM read_text('/Users/aloksubbarao/duckdb-skills/server/agent_stream_incremental.sql'));
FROM quack_query('quack:localhost:9494', getvariable('stream_program'), token := getenv('QUACK_TOKEN'));
