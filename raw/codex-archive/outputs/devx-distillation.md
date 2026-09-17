# DevX: first source-grounded distillation

Read from the private `asubbarao/devx-takeaways` repository on September 16, 2026. Scope: root index and case study, plus selected implementation and design files across all seven themes. This is a cross-theme first pass, not a line-by-line audit of every artifact. No ingestion system has been deployed.

## The organizing idea

Make engineering evidence durable and queryable; make agents consumers and interpreters of that evidence. Your case study already demonstrates the approach: a versioned repository corpus in DuckDB, deduplicated by path and content hash, served by one persistent engine to multiple readers. Extend that same substrate to operational evidence and reusable engineering knowledge.

## What transfers from each theme

| Theme | Source | Transfer to the shared system |
|---|---|---|
| DuckDB self-dispatch | `duckdb-self-dispatch/01-self-dispatch-molecule.sql`, `04-rest-client-macro.sql` | Endpoints are registry rows; requests and responses retain source identity; typed views turn responses into joins. |
| Agent orchestration | `agent-orchestration/12-trigger-and-completion-proof.md` | Completion requires fetched evidence for the intended version after the request. Apply this to deployment, migration, ingestion, and review. |
| Review quality | `review-quality/10-failure-pack-mandatory-checks.md`, `11-closed-loop-learning-append.md` | Confirmed misses become relevant, mandatory checks with provenance and an explicit verdict for every selected check. |
| How-to automation | `howto-automation/09-typed-phase-contract-dag.ts` | Declare input versions, output validation, retry policy, side-effect identity, and downstream invalidation. Translate these contracts into tables before choosing a scheduler. |
| Design and copy | `design-and-copy/13-orchestrator-with-taste.md` | Shared state carries decisions and rationale; give each agent a relevant slice. Synthesis requires judgment, not forwarding raw output. |
| Developer infrastructure | `dev-tooling-infra/velocity-dashboard-and-schema.md` | Collect stable PR identities, review/merge timing and collection timestamps; add deployments and runtime outcomes to explain delivery. |
| Data integrations | `data-integrations-misc/incident-rca-workflow.md`, `shared-memory-recall-capture.md` | Compare affected and unaffected cohorts, preserve temporal evidence, verify recovery, and distill knowledge by the questions people will ask. |

## A SQL-first implementation shape

1. **Source records:** API responses and repository versions, each with source URL, stable identity, content hash, observed time, source event time, and ingestion run ID.
2. **Collection state:** endpoint registry, cursor, watermark, retry deadline, response status, and completeness. Commit a page and its checkpoint together; resume failed runs. Periodically reconcile edits and deletions.
3. **Typed facts:** messages/replies, issues, PRs, commits, workflow attempts, deployment artifacts, migration runs, runtime observations, and distinct failures.
4. **Evidence links:** explicit IDs and release metadata first; inferred links carry their evidence and confidence. Time proximity alone does not establish causation.
5. **Queries and contracts:** incident rates, release lag, production/staging workload differences, missing test scenarios, and checks required by changed code.
6. **Shared access:** quackapi routes expose bounded queries and dashboards. Both Claude and Codex consume the same persisted records and provenance.

The intended operating model is one owner process for the persistent DuckDB file. Workers submit work to that owner. Pure SQL describes the transformations and contracts; an execution mechanism still has to wake collectors and enforce retries. Dagster can be added later if operating the schedule and dependency graph warrants it.

## Slack, http_client, and quackapi

Slack exposes ordinary HTTP APIs: `conversations.history` for channel history and `conversations.replies` for threads. Direct collection needs its own authorized token and appropriate conversation access; a working Codex connector does not establish a reusable token for DuckDB. Collect all cursor pages, inspect Slack's JSON `ok` field as well as HTTP status, and respect rate limits.

`http_client` supplies SQL HTTP calls. The current quackapi README additionally documents `quackapi_fetch` and `quackapi_post`, pooled outbound connections, structured responses, and volatile function registration. These can be the transport underneath provider-specific SQL adapters. Steampipe is an optional adapter where it saves implementation effort; the persisted fact model should not depend on it.

The repository examples are technique demonstrations, not verified production collectors: the REST macro interpolates values into curl commands and does not URL-encode query values. Prefer structured HTTP arguments. Its token cache, pagination, and error handling need implementation for real providers. Likewise, the self-dispatch document's parallelism claims need measurement against the exact engine and extension versions; CTE layout alone is not a durable execution guarantee.

Sources: https://docs.slack.dev/reference/methods/conversations.history/ ; https://github.com/asubbarao/quackapi ; https://github.com/asubbarao/httpclient

## Applying this to the Bob incident

Proposed failure class: long-lived requests retain resources that interfere with deployment or migration. The earlier inspected #1291 diff explicitly closes the auth DB session before returning the SSE response. The complete claim that this blocked the production rollout still requires deployment/migration logs; it is not established by that diff alone.

Turn the class into an executable scenario: hold an authenticated Bob SSE connection open on the old version; initiate migration and rolling deployment; measure transaction age and lock waits; verify bounded completion, actual serving version, and client recovery. Compare the result with an idle environment. Add reconnect and concurrent-session variants once the minimal reproducer is established.

The resulting query should answer: which production operating conditions did this release's tests never exercise? Record deployment age, open-stream count, transaction age, lock waits, migration revision, running artifact, and test coverage as evidence. This makes an omitted scenario visible rather than treating a green idle staging run as proof.

Measure distinct failed operations divided by attempted operations, grouped by actual running release and relevant workload. Preserve reporting-version changes: Ohad's #1298 explicitly documents increased Sentry events per failure, so alert counts alone can misstate the trend.

## First useful deliverable

A repository corpus plus one joined incident timeline spanning Slack, GitHub, Linear, and deployment/runtime evidence; one executable open-SSE deployment scenario; one failure-pack entry linked to its evidence. This demonstrates collection, analysis, and prevention together before broadening adapters to every service.
