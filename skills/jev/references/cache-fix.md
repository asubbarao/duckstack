# JEV cache fix: upstream PR and validation

[Upstream PR #3](https://github.com/judoaseeta/duckdb-jev/pull/3) is open, non-draft, at commit 304f069cc176107bf83551ffcac14607c8ba026e. It targets the extension source repository; community-extensions only registers the released source revision. [GitHub CI](https://github.com/judoaseeta/duckdb-jev/actions/runs/36667340849) reports action_required and awaits upstream maintainer approval. It has not passed remote CI or merged.

Requested repository owner judoaseeta as reviewer; GitHub denied RequestReviewsByLogin because contributor asubbarao lacks permission. The PR remains ready for human review with the reproduction, design, regression cases and validation described in its body.

In plain terms: cached answers used to survive changes to the model, endpoint, or credential. The fix keeps answers separate for each configuration, while identical calls still share answers.

Terra (gpt-5.6-terra) implemented the fix in an isolated worktree on branch fix/cache-config-isolation, based on upstream 58e548463b0bfb25d86bc68b11515a1daaf87ab3. Sol 6.1 reviewed it; the parent verified the final source/diff and independently reran the extension suite.

The cache now retains a SHA-256 namespace derived from length-delimited endpoint, model and credential identity. Same-configuration question/row sharing is retained. Configuration changes cannot reuse another configuration's entry. Plaintext credentials are not included in retained cache keys.

Changed files:
- src/include/jev_client.hpp
- src/jev_client.cpp
- src/jev_functions.cpp
- test/mock_api.py (accepts one additional fixed test credential)
- test/sql/jev_api.test

## Behavioral regression

Terra tested separate owned CLI processes with absolute LOAD paths against the same deterministic local HTTP transport fixture. This tests the actual extension's cache behavior; it does not test JEV model quality.

| Phase | Original signed artifact: newly evaluated rows | Patched artifact: newly evaluated rows |
|---|---:|---:|
| Initial evaluation | 3 | 3 |
| Identical configuration | 0 | 0 |
| Model changes | 0 (defect) | 3 |
| Endpoint changes | 0 (defect) | 3 |
| Accepted credential changes | 0 (defect) | 3 |

After warming identical rows with a valid fixture key and switching to an invalid fixture key without clearing:
- Original returned cached probabilities, bypassing the expected authentication failure.
- Patched artifact returned API error 401.

The signed original was loaded from /Users/aloksubbarao/.duck/extensions/v1.5.5/osx_arm64/jev.duckdb_extension. The patched artifact was loaded from the worktree's build/release/extension/jev/jev.duckdb_extension. These focused results were reported by Terra from its direct tool outputs.

## Fresh-build suite

A fresh pinned DuckDB v1.5.5 build produced the worktree artifact and statically linked test runner. The parent independently ran make test_mock through uv with DUCKDB_TEST_AUTOLOADING=none, preventing installed-extension autoloading. All three files ran: jev_api.test, jev_offline.test, jev_no_key.test. Final result: all tests passed (119 assertions in 3 cases), exit status 0. The suite contains configuration-switch and warmed-invalid-key regressions plus existing choice/score, batching, error/partial-cache and missing-key behavior. Final phase counters use ordered rows and lag, without MAX aggregations. The mock requires the exact Bearer header.

git diff --check passed. The five-file commit was pushed to asubbarao/duckdb-jev and submitted upstream. The changed files passed DuckDB's formatter with Black 24.10 and clang-format 11. The installed dev artifact was not replaced.

[Patch](jev-cache-isolation.patch) matches the submitted commit and applies to the pinned upstream base. This is an open contribution, not a published release. Live model inference in the separate exploration remains unverified because the selected dev process has no TypeSafe credential.
