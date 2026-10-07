-- ASSESSMENT (2026-09-30): for a one-off plist this method is SUBOPTIMAL. Prefer plutil, which is
-- built into macOS and needs no DuckDB, extension or server:
--     plutil -convert xml1 -o out.plist in.json     (not run here; standard plutil feature)
-- What this session found:
--   * json_to_xml (webbed) cannot express a plist <dict> (alternating <key>/<value> siblings) and
--     emits <true></true>, which launchd rejects (Bootstrap failed: 5) although plutil -lint passes it.
--   * tera_render autoescapes; an explicit `| escape` double-escapes (&amp;amp;).
--   * Dev was unreachable several times while doing this (ECONNREFUSED; the com.inframe.quack
--     launchd job was found unloaded). Cause NOT established: DiagnosticReports/duckdb-*.ips cover
--     every duckdb process on the machine, not only dev, and httpserver is not loaded on dev.
--     A server-side render is still a heavier dependency than plutil for one small file.
-- The ideas DO transfer: use this recursive-macro pattern when the plist (or any nested XML/JSON
-- document) is generated from rows or many configs, inside a SQL pipeline. Keep as a reference.
--
-- JSON -> Apple property list (launchd plist), one recursive Tera macro, no replace() chains.
-- Intent: author config as JSON, render it to XML with tera_render, write it with COPY (FORMAT blob).
-- Verified 2026-09-30 on dev: nested dicts, arrays, bool, int vs real, `&` escaping; plutil -lint OK,
-- and `launchctl bootstrap` accepts it.
--
-- Facts measured:
--   * json_to_xml (webbed) cannot express plist dicts: a plist <dict> is alternating <key>/<value>
--     siblings, which a JSON object cannot map to; arrays also gain *_list wrapper elements.
--     It also emits <true></true>, which launchd rejects (Bootstrap failed: 5) — plutil -lint passes it.
--   * tera_render autoescapes inline templates. Do NOT add `| escape` (double-escapes `&` to &amp;amp;).
--   * Tera has no boolean/integer tests: use `v == true` and `v == v | int`. Test bool first.
--   * Object keys render in sorted order; plist dict order does not matter.
--   * COPY (SELECT ...::BLOB) TO path (FORMAT blob) writes the text verbatim (no CSV quoting).
-- Edit: replace the $cfg$ JSON and the TO path. Loading is a separate step:
--   launchctl bootstrap gui/$(id -u) <path>

COPY (
SELECT tera_render($t${% macro val(v) -%}
{%- if v == true -%}<true/>
{%- elif v == false -%}<false/>
{%- elif v is object -%}<dict>{% for k, x in v %}<key>{{ k }}</key>{{ self::val(v=x) }}{% endfor %}</dict>
{%- elif v is iterable -%}<array>{% for x in v %}{{ self::val(v=x) }}{% endfor %}</array>
{%- elif v is number -%}{% if v == v | int %}<integer>{{ v }}</integer>{% else %}<real>{{ v }}</real>{% endif %}
{%- else -%}<string>{{ v }}</string>
{%- endif -%}
{%- endmacro val -%}
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">{{ self::val(v=cfg) }}</plist>
$t$, json_object('cfg', $cfg${"Label":"com.example.job","ProgramArguments":["/bin/echo","hello"],"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":60}$cfg$::JSON))::BLOB AS plist
) TO '/tmp/com.example.job.plist' (FORMAT blob);
