-- Binding checks only: no provider calls or persistent fixtures.
INSTALL jev FROM community;
LOAD jev;

EXPLAIN WITH source AS (SELECT 'Please return the duplicate charge.' AS body)
SELECT *, jev_prob(body, 'The customer explicitly requests money back.') AS probability,
    jev_eval(body, 'Which team owns the requested action?', 'choice',
        ['billing','technical','sales','other']) AS raw_team_answer
FROM source;

EXPLAIN WITH source AS (SELECT 'document-a' AS document_id,
    'Loss history for the preceding year' AS requested_evidence,
    'Five claims with dates and paid amounts for the preceding year' AS excerpt)
SELECT document_id, requested_evidence, excerpt,
    struct_pack(requested_evidence := requested_evidence, excerpt := excerpt) AS payload,
    sha256(to_json(payload)) AS input_hash,
    jev_eval(payload, 'Does the excerpt supply the requested evidence?', 'choice',
        ['supports','does_not_support','insufficient_evidence']) AS raw_answer
FROM source;

EXPLAIN WITH source AS (SELECT 'Nobody can sign in today.' AS body)
SELECT *, jev_score_norm(body, 'How urgent is the described problem?',
    ['routine','time_sensitive','blocked']) AS urgency FROM source;

EXPLAIN WITH source AS (SELECT 'Please return the duplicate charge.' AS body)
SELECT *, jev_choice(body, 'Which team owns this?', ['billing','other']) AS team,
    jev_confidence(body, 'Which team owns this?', 'choice', ['billing','other']) AS confidence
FROM source;

EXPLAIN WITH source AS (SELECT 'Please return the duplicate charge.' AS body)
SELECT * FROM source WHERE jev(body, 'The customer requests money back.', 0.8);
