---
name: crawl
description: >
  Read web pages as relations through System Quack, preserving raw responses and explicit crawl
  limits. Use native duckdb MCP and inspect installed crawler/webbed signatures before crawling.
argument-hint: "<url | seed relation | --chrome> [crawl options]"
---

Read `/duckstack:duck` and `/duckstack:query` first. The planned runtime is not deployment
evidence. When native `duckdb` MCP is unavailable, report that selected-service failure; do not
use the old sidecar or another endpoint.

## Discover and bound the crawl

Use native `tools/list`, then inspect `duckdb_extensions()` and `duckdb_functions()` for the
installed `crawler`, `webbed`, URL, and reader functions. Install/load a missing extension through
native `quack_query`, re-inspect its actual signature, and prove one bounded invocation.

Every crawl body must state and preserve: seed relation/URLs, timeout, workers, batch size, delay,
link-following rule, depth, cache policy, and result limit. Preserve status, headers, raw body,
redirect/error metadata, and source URL. An error page or failed response never becomes a seed.

Seed crawling and correlated per-row crawling are different. Use an installed seed function only
after inspecting its signature. Use `crawl_url` only as an explicit correlation:

```sql
FROM seeds
CROSS JOIN LATERAL crawl_url(seeds.url, /* actual named parameters and limits */);
```

Keep raw rows in `workspace.raw_<name>` and derive parsed/selected relations separately. A 10,000
row MCP response cap means large raw data should remain in workspace and later reads should be
bounded/aggregated. Do not paste a large response into conversation.

For authenticated/SPAs, use the existing logged-in Chrome route only when the task authorizes it;
do not open a fresh profile or mutate the user's tabs. Treat browser markup as raw input and parse
with the extension's typed HTML/XML functions after checking their actual signatures.
