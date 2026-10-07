-- Sentry's event JSON endpoint is read through DuckDB's HTTP filesystem. Keep the
-- credential in the launchd environment and create only an in-memory, scoped
-- secret at startup so read_json/read_json_auto can authenticate without a
-- token in SQL or the database file.
SET VARIABLE sentry_auth_token = nullif(getenv('SENTRY_AUTH_TOKEN'), '');
CREATE TEMPORARY SECRET sentry_http (
    TYPE HTTP,
    BEARER_TOKEN getvariable('sentry_auth_token'),
    SCOPE 'https://us.sentry.io'
);
RESET VARIABLE sentry_auth_token;
-- Keep the other local API credentials in the launchd environment as well,
-- but expose them to DuckDB HTTP readers through scoped secrets. The values
-- are never written into setup.sql or the database; getenv() is evaluated at
-- service startup and the temporary variables are cleared immediately.
SET VARIABLE github_api_token = nullif(getenv('GITHUB_TOKEN'), '');
CREATE TEMPORARY SECRET github_http (
    TYPE HTTP,
    BEARER_TOKEN getvariable('github_api_token'),
    SCOPE 'https://api.github.com'
);
RESET VARIABLE github_api_token;
SET VARIABLE slack_api_token = nullif(getenv('SLACK_TOKEN'), '');
CREATE TEMPORARY SECRET slack_http (
    TYPE HTTP,
    BEARER_TOKEN getvariable('slack_api_token'),
    SCOPE 'https://slack.com'
);
RESET VARIABLE slack_api_token;
SET VARIABLE linear_api_token = nullif(getenv('LINEAR_API_KEY'), '');
CREATE TEMPORARY SECRET linear_http (
    TYPE HTTP,
    BEARER_TOKEN getvariable('linear_api_token'),
    SCOPE 'https://api.linear.app'
);
RESET VARIABLE linear_api_token;
