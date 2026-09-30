-- Selected dev. Replace SELECT input with a file reader; preserve source rows.
-- Real inference requires TypeSafe credentials. Binding checks: jev_explain.sql.
-- Previous notebook: archive/2026-09-29-original/jev_useful_queries.sql.
INSTALL jev FROM community;
LOAD jev;

WITH source AS (SELECT 'Please return the duplicate charge.' AS body)
SELECT *, jev_prob(body, 'The customer explicitly requests money back.') AS probability,
    jev_eval(body, 'Which team owns the requested action?', 'choice',
        ['billing','technical','sales','other']) AS raw_team_answer
FROM source;

WITH source AS (SELECT 'document-a' AS document_id,
    'Loss history for the preceding year' AS requested_evidence,
    'Five claims with dates and paid amounts for the preceding year' AS excerpt)
SELECT document_id, requested_evidence, excerpt,
    struct_pack(requested_evidence := requested_evidence, excerpt := excerpt) AS payload,
    sha256(to_json(payload)) AS input_hash,
    jev_eval(payload, 'Does the excerpt supply the requested evidence?', 'choice',
        ['supports','does_not_support','insufficient_evidence']) AS raw_answer
FROM source;

-- Profile a reader/query directly; no fixture tables or manual bean counting.
DESCRIBE SELECT 'Please return the duplicate charge.' AS body;
SUMMARIZE SELECT 'Please return the duplicate charge.' AS body;

-- Local type detection before semantic enrichment; no provider request.
INSTALL finetype FROM community;
LOAD finetype;
SELECT 'https://example.com' AS input, ft_infer(input) AS detected_type;

-- Generated input, not model output; keep the generated rows for repeatable comparisons.
INSTALL fakeit FROM community;
LOAD fakeit;
SELECT fakeit_address_city() AS city, fakeit_address_country() AS country FROM range(4);
