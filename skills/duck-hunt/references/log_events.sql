-- One row per parser event; an unmatched document remains one row with NULL event_id.
-- CI_LOG_PATH is a file or glob; CI_LOG_FORMAT is e.g. junit_xml, pytest_json, gcc_text.
-- raw_log and source_path remain evidence. A parser outcome is not an acquisition receipt.
INSTALL duck_hunt FROM community;
LOAD duck_hunt;
-- XML report parsers delegate to webbed; load it in this connection, not only install it.
INSTALL webbed FROM community;
LOAD webbed;

WITH sources AS (
    SELECT filename AS source_path, content AS raw_log
    FROM read_text(getenv('CI_LOG_PATH'))
)
SELECT sources.*, events.*
FROM sources
LEFT JOIN LATERAL parse_duck_hunt_log(raw_log, getenv('CI_LOG_FORMAT')) events ON true
WHERE CASE WHEN getenv('CI_LOG_FORMAT') IN (SELECT format FROM duck_hunt_formats())
           THEN true ELSE error('Unknown format; choose a name from duck_hunt_formats()') END;
-- parse_duck_hunt_log(content, format): retain default severity='all', content='full',
-- context=0, include_unparsed=false, ignore_errors=false. event_id is local to each parse;
-- use (source_path, log_line_start, event_id) within this result, not event_id globally.
