-- events.sql: every query_end on this process (has_error, error_message, error_type) from the `events` community
-- extension, one JSON line each, appended by tee to raw/events/events.ndjson and read back as query_events.
-- NOT yet .read by setup.sql: community-extensions pins events at an April ref built for v1.5.2-v1.5.4 only, and
-- v1.5.5 is a 404. setup runs under -bail, so a failed INSTALL would stop the server. Once
-- `INSTALL events FROM community` works on this version, .read this file from setup.sql before the configuration lock.
-- events_destination is exec'd without a shell; arguments split on spaces (measured on v1.5.4). tee also copies each
-- line to its stdout, the server's server-<id>.out log. The handler runs no SQL, so there is no event feedback loop.
-- Each query_end arrives twice; a failed query's pair carries one has_error = true and one false.
INSTALL events FROM community;
LOAD events;
FROM read_text('mkdir -p /Users/aloksubbarao/.duck/raw/events && touch /Users/aloksubbarao/.duck/raw/events/events.ndjson |');
SET GLOBAL events_destination = '/usr/bin/tee -a /Users/aloksubbarao/.duck/raw/events/events.ndjson';
SET GLOBAL events_types = ['query_end'];
SET GLOBAL events_session_name = 'dev';
SET GLOBAL events_async = true;
CREATE OR REPLACE VIEW query_events AS
FROM read_json('/Users/aloksubbarao/.duck/raw/events/events.ndjson', format = 'newline_delimited',
    columns = {event: 'VARCHAR', "timestamp": 'TIMESTAMPTZ', session_name: 'VARCHAR', process_id: 'BIGINT',
               connection_id: 'BIGINT', query_id: 'BIGINT', transaction_id: 'BIGINT', has_error: 'BOOLEAN',
               error_type: 'VARCHAR', error_message: 'VARCHAR', database_path: 'VARCHAR'});
