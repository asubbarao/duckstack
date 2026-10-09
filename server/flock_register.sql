LOAD flock;
CREATE OR REPLACE PERSISTENT SECRET ollama_local (TYPE OLLAMA, API_URL '127.0.0.1:11434');
CREATE GLOBAL MODEL('session_summary_qwen', 'qwen3.6:35b', 'ollama', '{"max_batch_size":3,"is_async":true,"model_parameters":{"temperature":0,"num_ctx":32768}}');
SELECT * FROM flock_config.FLOCKMTL_MODEL_USER_DEFINED_INTERNAL_TABLE;