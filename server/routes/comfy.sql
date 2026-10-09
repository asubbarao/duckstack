-- Blind Apple Silicon render routes for QuackAPI (generic names only).
-- POST /call_models (+ /render). Helper streams via SaveImageWebsocket → image_b64 (zero Mac disk).
CREATE OR REPLACE ROUTE call_models POST '/call_models'
PARAM prompt VARCHAR
PARAM negative VARCHAR DEFAULT ''
PARAM width VARCHAR DEFAULT '1024'
PARAM height VARCHAR DEFAULT '1024'
PARAM steps VARCHAR DEFAULT '20'
PARAM seed VARCHAR DEFAULT ''
PARAM ckpt VARCHAR DEFAULT 'lustifySDXLNSFWSFW_v20.safetensors'
PARAM engine VARCHAR DEFAULT 'mps'
AS SELECT * FROM read_json(
  '/Users/aloksubbarao/ComfyUI/.venv/bin/python /Users/aloksubbarao/duckdb-skills/server/routes/comfy_generate.py'
  || ' --prompt-b64 ' || to_base64(encode(coalesce($prompt, '')))
  || ' --negative-b64 ' || to_base64(encode(coalesce(nullif($negative, ''), ' ')))
  || ' --width ' || regexp_replace(coalesce(nullif($width, ''), '1024'), '[^0-9]', '', 'g')
  || ' --height ' || regexp_replace(coalesce(nullif($height, ''), '1024'), '[^0-9]', '', 'g')
  || ' --steps ' || regexp_replace(coalesce(nullif($steps, ''), '20'), '[^0-9]', '', 'g')
  || ' --seed ' || regexp_replace(coalesce(nullif($seed, ''), '0'), '[^0-9]', '', 'g')
  || ' --model ' || regexp_replace(coalesce(nullif($ckpt, ''), 'lustifySDXLNSFWSFW_v20.safetensors'), '[^A-Za-z0-9._-]', '', 'g')
  || ' --engine ' || regexp_replace(coalesce(nullif($engine, ''), 'mps'), '[^A-Za-z0-9._-]', '', 'g')
  || ' --return-b64 1'
  || ' |'
);

CREATE OR REPLACE ROUTE render POST '/render'
PARAM prompt VARCHAR
PARAM negative VARCHAR DEFAULT ''
PARAM width VARCHAR DEFAULT '1024'
PARAM height VARCHAR DEFAULT '1024'
PARAM steps VARCHAR DEFAULT '20'
PARAM seed VARCHAR DEFAULT ''
PARAM ckpt VARCHAR DEFAULT 'lustifySDXLNSFWSFW_v20.safetensors'
PARAM engine VARCHAR DEFAULT 'mps'
AS SELECT * FROM read_json(
  '/Users/aloksubbarao/ComfyUI/.venv/bin/python /Users/aloksubbarao/duckdb-skills/server/routes/comfy_generate.py'
  || ' --prompt-b64 ' || to_base64(encode(coalesce($prompt, '')))
  || ' --negative-b64 ' || to_base64(encode(coalesce(nullif($negative, ''), ' ')))
  || ' --width ' || regexp_replace(coalesce(nullif($width, ''), '1024'), '[^0-9]', '', 'g')
  || ' --height ' || regexp_replace(coalesce(nullif($height, ''), '1024'), '[^0-9]', '', 'g')
  || ' --steps ' || regexp_replace(coalesce(nullif($steps, ''), '20'), '[^0-9]', '', 'g')
  || ' --seed ' || regexp_replace(coalesce(nullif($seed, ''), '0'), '[^0-9]', '', 'g')
  || ' --model ' || regexp_replace(coalesce(nullif($ckpt, ''), 'lustifySDXLNSFWSFW_v20.safetensors'), '[^A-Za-z0-9._-]', '', 'g')
  || ' --engine ' || regexp_replace(coalesce(nullif($engine, ''), 'mps'), '[^A-Za-z0-9._-]', '', 'g')
  || ' --return-b64 1'
  || ' |'
);
