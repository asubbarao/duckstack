-- Extensions the portable CI readers use; installation is cached, loading is per connection.
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL duck_hunt FROM community; LOAD duck_hunt;
INSTALL duck_tails FROM community; LOAD duck_tails;
INSTALL scalarfs FROM community; LOAD scalarfs;

COPY (SELECT trim(content, E' \t\r\n') FROM read_text('git rev-parse --show-toplevel |'))
TO 'variable:repo' (FORMAT variable, LIST none, USE_TMP_FILE false);
