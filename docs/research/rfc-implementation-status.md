# RFC implementation status

Reviewed against commit `2652484` on 2026-09-27. Each row compares a requirement in [the RFCs](../rfc.md) with source code, tests and the records in `docs/decisions/` and `docs/research/`. No checks were run for that review; the Coverage column names existing specs and `scripts/check` targets. Rows have since been updated as the implementation closed each gap, and each updated row cites the check that proves it.

Status values:

- **Implemented**: the requirement works as specified, or as the RFC now states after an amendment recorded in an ADR.
- **Diverged**: a working alternative uses a different design or name.
- **Partial**: only part of the requirement works.
- **Absent**: there is no implementation.
- **Unverifiable**: a performance, scale or business claim has no measurement.
- **Deferred (performance)**: the row is only a performance, scale or token-savings number. Another row implements its functional behaviour, and the measurement is deferred.
- **Blocked**: the work needs an action outside the repository. The row names the command that unblocks it.

Update a row when its status changes, and cite the change or check that proves it.

## Summary

All eight RFCs are marked Approved; none is complete. Work so far has concentrated on Caramel Core, the local environment (Latte) and the application CLI (Frappé). Queues, deployment, and most of the planned data-layer and agent tooling have not started.

| RFC | Overall | State |
|---|---|---|
| 0001 Caramel Core | Implemented | Compile-time routes and contracts, allocation-free matching, multi-target partials, islands and dual egress all work. `scripts/check browser` verifies morph focus and scroll, `hx-partial` ingestion, the island lifecycle and SSE through Caddy in Safari. The RFC text is amended by ADRs [0003](../decisions/0003-core-routing-and-contracts.md), [0004](../decisions/0004-htmx4-fragment-negotiation.md) and [0005](../decisions/0005-island-props-helper.md). |
| 0002 SugarORM | Diverged (narrowed) | By [decision 0002](../decisions/0002-typed-persistence.md), `Caramel::Model` provides scalar CRUD and explicit SQL migrations. Associations, changesets, schema diffs and migration lints are absent. |
| 0003 Cold Brew | Absent | Only the generic streaming response `Action#stream` exists. |
| 0004 Latte | Partial | Native PostgreSQL, CoreDNS and Caddy supervision and per-site databases work. Database branching is absent. System DNS, standard ports and CA trust are prepared but not applied. |
| 0005 Frappé | Partial | The `frappe` CLI covers the project workflow. The agent command surface, `check` and machine-output mode are absent. |
| 0006 Corretto | Partial | Generated request specs run against a separate per-site spec database. Savepoints, per-worker databases, queue draining and wire-level fakes are absent. |
| 0007 Roast | Absent | There is no static artifact, asset embedding, deployment or SDK; only an optional release-build measurement exists. |
| 0008 Poetic ergonomics | Partial | Contract, handle and response actions work with typed, nil-safe input. Domain DSLs, semantic units, Slang and `caramel expand` do not exist. |

## Ranked gaps and divergences

1. **No production path (RFC-0007).** There is no static Linux artifact, embedded assets, deployment command, cutover or rollback, so Caramel cannot ship an application it builds. The Linux/musl artifact is an open gate in `docs/research/frappe-workflow.md` and `docs/decisions/0001-managed-toolchain-provider.md`.
2. **Data-layer guarantees are missing (RFC-0002, RFC-0008).** Caramel lacks associations and preload safety, changesets, schema diffs and migration lints. The migrator runs each batch in one transaction, so `CREATE INDEX CONCURRENTLY` cannot run. Most applications need relations early; decision 0002 names that need as the trigger to reconsider an upstream ORM.
3. **No background work or PubSub (RFC-0003).** Jobs, scheduling, `LISTEN`/`NOTIFY` and caching are absent. RFC-0006 queue draining and RFC-0008 `invite`-style operations depend on them, and dual-write safety has no mechanism.
4. **The real user path is partly proven.** `scripts/check browser` drives Safari through Latte's Caddy proxy to a live generated application on a `.localhost` site. That covers morph focus and scroll, `hx-partial` ingestion, the island lifecycle and SSE. Still unapplied: the `.caramel` system resolver, ports 80/443 and CA trust. Safari accepts the check's untrusted local CA only through WebDriver's `acceptInsecureCerts`.
5. **Test isolation (RFC-0006).** Examples share one spec database and clean up with `ensure` blocks. Without savepoint rollback or per-worker databases, suites will slow down and leak state as applications grow.
6. **Edit-loop latency (RFC-0004 §2.1, RFC-0005 §2.2).** Polling plus full native builds give p95 compiled-edit latencies of 4.55 s and 7.76 s. The RFCs promise feedback under 200 ms and set a three-second target. Semantic checks take 1.67 s and 3.74 s against the promised 180 ms. The compiler profile shows that faster process handoff alone cannot close the gap.
7. **No database branching (RFC-0004 §2.2).** Per-site development and spec databases stand in for branches. `db:branch`, per-worker test databases and the diff engine's scratch catalog all depend on branching.
8. **No agent tooling (RFC-0005).** There is no `agent-manifest`, `check` command or `--agent` mode. MRDP output exists only for HTTP 422 contract errors, and invalid CLI input exits 2 rather than the RFC's 1.
9. **The RFC text no longer matches the code.** Examples:
   - RFC-0001 no longer differs: ADRs 0003–0005 amended its routing, contract, island and fragment-header text.
   - RFC-0005 §3 specifies exit code 1; the CLI returns 2.
   - The RFCs name a `caramel` CLI; the implemented CLI is `frappe`.
   - The planned `src/core/**` tree is actually `src/caramel`, `src/latte` and `src/frappe`.
   - RFC-0004 names `/tmp/.s.PGSQL.5432`; Latte uses a private socket directory.
   - RFC-0008 specifies Slang; views use ECR.
   Every RFC still says only "Approved", so readers and agents following it write code that does not compile or behaves differently.
10. **The rest of RFC-0008 is missing.** Semantic units, `caramel expand` and domain DSLs are absent.

## RFC-0001 Caramel Core

| Requirement | Status | Evidence | Coverage | Notes |
|---|---|---|---|---|
| §2.1 compile-time route and contract verification | Implemented | `Caramel::Router.draw` (`src/caramel/http/router.cr`) resolves each action and requires a `contract`. It checks each `:param` against the generated `CARAMEL_FIELD_*` constants: the field must exist, have type String, Int32 or Int64, and be neither nilable nor defaulted. | `scripts/check route-compilation` (including `compile_defaulted_param`), `spec/caramel/router_spec.cr` | RFC-0001 §2.1 now describes the constants ([ADR 0003](../decisions/0003-core-routing-and-contracts.md)). |
| §2.1 regex-free radix dispatch; matching allocates nothing | Implemented | `Router::Tree` is built once from the compile-time table. `Segments` is a stack value holding byte offsets, and each route has a generated method. | `spec/caramel/router_spec.cr` (the GC allocation counter shows that matching, including backtracking and method masks, allocates nothing) | RFC-0001 §2.1 is amended: binding allocates the decoded parameters and the contract ([ADR 0003](../decisions/0003-core-routing-and-contracts.md)). Full-dispatch throughput is a deferred performance question. |
| §2.2 request contracts | Implemented | `Caramel::RequestContract` (`src/caramel/contracts/request_contract.cr`), `RequestInput` (`src/caramel/http/request_input.cr`) | `spec/caramel/request_contract_spec.cr`, `spec/caramel/request_input_spec.cr`, `scripts/check contract-compilation` | RFC-0001 §2.2 now shows the `contract do; field …; end` and `Contract.parse` API ([ADR 0003](../decisions/0003-core-routing-and-contracts.md)). Invalid route parameters return 404; other invalid fields return 422. |
| §2.3 morph swaps preserving focus and scroll | Implemented | `Partial` and `morph` default to `innerMorph` (`src/caramel/hypermedia.cr`, `src/caramel/action.cr`), and the generated layout inherits it | `scripts/check browser` | In Safari, a live-search morph keeps the same input element focused with its caret and value, and keeps a scrolled list's `scrollTop`. The `innerHTML` control loses focus, which shows the check can fail. |
| §2.3 multi-target `hx-partial` | Implemented | `Action#partials`, `Action#morph`, `Hypermedia.render` | `spec/caramel/action_spec.cr`, `spec/caramel/hypermedia_spec.cr`, `scripts/check browser` | In Safari, one CSRF-protected htmx POST updates two disjoint targets with different swaps and leaves an unrelated region untouched. |
| §2.4 islands | Implemented | `Action#island`, `Caramel::Island` (`src/caramel/islands.cr`), `src/caramel/islands.js` | `spec/caramel/hypermedia_spec.cr`, `scripts/check browser` | RFC-0001 §2.4 now shows `island("Name", props)` and the client lifecycle ([ADR 0005](../decisions/0005-island-props-helper.md)). Safari confirms mount, late registration, `update` on a props morph with client state intact, and `unmount`. |
| §2.5 `HX-Request-Type: partial` returns a fragment | Implemented | `RequestContext#partial?` tests `HX-Request-Type: partial`. `HX-Request: true` selects HTML over JSON and `HX-Location` redirects (`src/caramel/http/request_context.cr`, `src/caramel/response.cr`). | `spec/caramel/action_spec.cr`, `templates/application/spec/requests/home_spec.cr`, `scripts/check browser` | RFC-0001 §2.5 is amended because htmx 4 sends `HX-Request: true` for full-document requests too ([ADR 0004](../decisions/0004-htmx4-fragment-negotiation.md)). |
| §2.5 `Accept: application/json` serializes the result | Implemented | `RequestContext#wants_json?`, `Action#json`, `Action#respond` (`src/caramel/action.cr`) | `spec/caramel/action_spec.cr`, generated resource request specs | RFC-0001 §2.5 now says that a `Response` returned by `handle` is explicit egress and passes through unchanged ([ADR 0004](../decisions/0004-htmx4-fragment-negotiation.md)). |
| §3 route-collision rejection | Implemented | `Router.draw` rejects duplicate routes and ambiguous ordering at compile time | `scripts/check route-compilation` | A static route declared before a dynamic one takes precedence, as the amended §3 states. |
| §3 2 MB form cap; uploads streamed to disk | Implemented | `RequestInput::MAX_FORM_BYTES` (2 MiB) and `MAX_UPLOAD_BYTES` (64 MiB); `HTTP::FormData.parse` into `File.tempfile` | `spec/caramel/request_input_spec.cr` | RFC-0001 §3 now names `RequestInput` ([ADR 0003](../decisions/0003-core-routing-and-contracts.md)). |

## RFC-0002 SugarORM

| Requirement | Status | Evidence | Coverage | Notes |
|---|---|---|---|---|
| §2.1 pure, immutable schema structs | Diverged | `Caramel::Model` (`src/caramel/model.cr`): `table`, `field`, mutable properties, `save` and `delete`, no callbacks | `spec/caramel/model_spec.cr`, `spec/integration/model_spec.cr`, `scripts/check model-compilation` | Chosen by `docs/decisions/0002-typed-persistence.md`. The `SugarORM` namespace does not exist. |
| §2.1–2.2 associations typed as `NotLoaded \| Array(T)`; preload compile errors | Absent | `Model::Query` supports only `where`, `order`, `limit` and `to_a`, plus `find` | none | Excluded by decision 0002. |
| §2.3 fluent `update` expanding to a changeset | Diverged | Generated update actions assign fields, then call `save` (`templates/resource/app/actions/@@PLURAL@@/update.cr`) | generated resource request specs via `scripts/check frappe-project` | |
| §2.4 explicit typed changesets and rich validation | Absent | Only presence validation exists | `spec/caramel/model_spec.cr` | |
| §2.5 branch-and-diff migrations (catalog snapshot, introspection, AST diff, derived DDL) | Absent | `Caramel::Migrator` (`src/caramel/migration.cr`) applies hand-written SQL with a checksummed journal, advisory lock and one transaction per batch. The resource generator emits `CREATE TABLE`. | `spec/caramel/migration_spec.cr`, `spec/integration/database_spec.cr`, `scripts/check frappe-project` | `db/schema.cr` is a placeholder. |
| §2.6 migration lints (concurrent indexes, non-null additions, `renamed_from:`) | Absent | No DDL analysis | none | The per-batch transaction also prevents `CREATE INDEX CONCURRENTLY`. |
| §3 typed `SugarORM.sql` block | Absent | Only bound crystal-db SQL exists | `spec/integration/database_spec.cr` | Excluded by decision 0002. |
| §3 `--dev-override`; strict staging lint | Absent | — | none | Depends on the missing lints. |

## RFC-0003 Cold Brew

| Requirement | Status | Evidence | Coverage | Notes |
|---|---|---|---|---|
| §2.1 `caramel_jobs` table; transactional enqueue with `SKIP LOCKED` | Absent | — | none | |
| §2.2 worker fibers; `run_at` scheduling | Absent | — | none | |
| §2.3 PubSub over SSE | Partial | `Action#stream`, `Response.stream` and streaming in `Caramel::Application`; Frappé's `DevGateway` forwards event streams unbuffered | `spec/caramel/streaming_spec.cr`, `spec/frappe/dev_gateway_spec.cr`, `scripts/check browser` | No `LISTEN`/`NOTIFY` broker or subscriptions exist yet. In Safari, events arrive through Caddy unbuffered. |
| §2.4 `UNLOGGED` cache | Absent | — | none | |
| §3 time-partitioned job tables | Absent | — | none | |

## RFC-0004 Latte

| Requirement | Status | Evidence | Coverage | Notes |
|---|---|---|---|---|
| §2.1 native supervision without Docker | Diverged | The Latte daemon supervises PostgreSQL, CoreDNS and Caddy (`src/latte/supervisor.cr`, `src/latte/process.cr`); applications run under terminal-owned `frappe dev` | `spec/latte_integration/supervisor_spec.cr`, `scripts/check latte-daemon`, `scripts/check frappe-project --dev` | Design recorded in `docs/research/herd-comparison.md`. |
| §2.1 Unix-socket PostgreSQL at `/tmp/.s.PGSQL.5432` | Diverged | Private socket directory, `listen_addresses = ''`, SCRAM (`src/latte/postgres.cr`) | `spec/latte_integration/postgres_spec.cr`, `scripts/check latte-postgres` | Uses a private per-state-root socket, not a shared `/tmp` socket. |
| §2.1 kqueue/inotify watching; `--no-codegen` feedback under 200 ms | Diverged | `src/frappe/dev_files.cr` polls hashed snapshots; `src/frappe/dev_session.cr` debounces for 200 ms and runs a full `crystal build -D caramel_development` | `spec/frappe/dev_files_spec.cr`, `scripts/check frappe-project --dev` | Measured compiled-edit p95: 4.55 s and 7.76 s; semantic check: 1.67 s and 3.74 s (`docs/research/development-performance.md`). |
| §2.2 `caramel latte branch create` with a connection guard and template clone | Absent | `latte` offers only `daemon` and `trust install\|remove` (`src/latte.cr`). Sites get `caramel_dev_<id>` and `caramel_spec_<id>` databases created from `template0`. | none for branching | Per-site databases plus `frappe db dump\|restore` stand in for branches. |
| §2.2 50–100 ms reflink clone | Unverifiable | No clone exists | none | |
| §3 restore `ALLOW_CONNECTIONS` on SIGINT/SIGTERM | Absent | Nothing disables connections. After a crash, the daemon adopts or restarts services. | `scripts/check latte-daemon` | General crash recovery exists. |
| Named `.caramel` DNS and HTTPS | Partial | CoreDNS on 127.0.0.1:15353 and a Caddy local CA on ports 18080/18443 (`src/latte/dns.cr`, `src/latte/proxy.cr`, `src/latte/supervisor.cr`) | `spec/latte/network_config_spec.cr`, `scripts/check latte-network` | Checks pass an explicit CA to `curl --resolve`. |
| System resolver, ports 80/443 and CA trust | Partial (prepared) | `tools/installer/install_local_integration.swift`, `latte/macos/PortRelay.swift`, `src/latte/trust.cr` | `scripts/check native` | Not yet applied; browser-trusted HTTPS acceptance is pending (`docs/research/latte-supervisor.md`). |

## RFC-0005 Frappé

| Requirement | Status | Evidence | Coverage | Notes |
|---|---|---|---|---|
| §2.1 stateless CLI surface | Diverged | `frappe` (`src/frappe/cli.cr`) with `new setup dev make migrate seed routes test db logs services sites installations doctor open lsp`; most project commands call the Latte daemon | `spec/frappe/cli_spec.cr`, `scripts/check frappe-project` | The command is `frappe`, not `caramel`. |
| §2.1 `agent-manifest` | Absent | `frappe --help` is the discovery surface | none | |
| §2.1–2.2 `check` (Tier-1 `--no-codegen` emitting MRDP) | Absent | `--no-codegen` runs only in contributor checks such as `scripts/checks/route_compilation.cr` and in benchmarks | `scripts/check route-compilation` | |
| §2.1 `routes [filter]` | Diverged | `frappe routes` prints every route with its contract and has no filter | `scripts/check frappe-project` | |
| §2.1 `db:branch`, `db:diff` | Absent | Only `frappe db dump\|restore` exists | none | These depend on RFC-0004 branching and RFC-0002 diffing. |
| §2.1 `corretto [path]` | Absent | `frappe test` runs Crystal specs | `scripts/check frappe-project` | |
| §2.2 native builds only at deployment | Diverged | `frappe dev`, `routes`, `migrate` and `seed` compile native binaries (`src/frappe/tools.cr`, `src/frappe/dev_session.cr`) | `scripts/check frappe-project` | |
| §2.3 Mode A: human TTY diagnostics | Diverged | Compiler output is forwarded to the terminal. Build and runtime errors render as HTML pages at the site origin (`src/frappe/dev_gateway.cr`, `src/caramel/development_error.cr`). | `spec/frappe/dev_gateway_spec.cr`, `scripts/check runtime-diagnostics` | |
| §2.3 Mode B: `--agent` or non-TTY MRDP | Partial | `RequestContract#to_mrdp` emits `ERR CONTRACT_INVALID:422` for HTTP clients that accept neither HTML nor JSON | `spec/caramel/request_contract_spec.cr` | There is no CLI agent mode, source location or `PATCH` line. |
| §2.2–2.3 ~180 ms Tier-1 check; >70% token savings | Unverifiable | Semantic checks measured at 1.67 s and 3.74 s | `scripts/check frappe-project --benchmark` | Token use has not been measured. |
| §3 unknown input exits 1 with one-line syntax | Diverged | Unknown commands and malformed arguments exit 2 with a usage line; unknown commands also get a suggestion | `spec/frappe/cli_spec.cr` | `frappe test` and `frappe lsp` forward extra arguments. |

## RFC-0006 Corretto

| Requirement | Status | Evidence | Coverage | Notes |
|---|---|---|---|---|
| §2.1 subcutaneous request, database and response assertions | Partial | Generated request specs call the application handler and check persisted rows and HTML, JSON and HX responses (`templates/resource/spec/requests/@@PLURAL@@_spec.cr`) | generated specs via `scripts/check frappe-project` | There is no `Corretto.session`, `sign_in` or custom matcher. |
| §2.1 mocking forbidden | Absent | No enforcement | none | Current specs happen to use real components. |
| §2.2 Tier 1: one template-cloned database per worker | Absent | `frappe test` verifies the one per-site spec database, migrates it and runs specs | `scripts/check frappe-project` | Spec-worker isolation is a remaining gate in `docs/research/frappe-workflow.md`. |
| §2.2 Tier 2: `SAVEPOINT` rollback per example | Absent | `templates/application/spec/spec_helper.cr` opens one connection per suite; generated specs delete their rows in `ensure` | none | |
| §2.2 Tier 3: catalog reset after DDL | Absent | — | none | |
| §2.3 synchronous queue drain | Absent | No queue exists (RFC-0003) | none | |
| §2.4 wire-level fakes (`Corretto.stub_wire`) | Absent | — | none | |
| §3 `--concurrency`, one database per worker | Absent | `frappe test` forwards Crystal spec options only | none | |
| §2.2 isolation under 1 ms | Unverifiable | The whole spec command takes 6.08 s and 12.72 s | `scripts/check frappe-project --benchmark` | |

## RFC-0007 Roast

| Requirement | Status | Evidence | Coverage | Notes |
|---|---|---|---|---|
| §2.1 asset inlining | Diverged | Assets are copied to `public/assets` and read from disk on each request (`src/caramel/application.cr`, `src/frappe/dev_files.cr`) | `spec/caramel/application_spec.cr`, `spec/frappe/dev_files_spec.cr` | |
| §2.1 static musl binary | Partial | `scripts/check frappe-project --benchmark` optionally makes a `--release` build: 2.73 MiB and 3.53 MiB | benchmark only | There is no `--static` or musl build. The Linux/musl artifact is deferred (`docs/research/frappe-workflow.md`, `docs/decisions/0001-managed-toolchain-provider.md`). |
| §2.2 SSH upload, zero-lock migration, `SO_REUSEPORT` handover | Absent | Development only: `frappe dev` health-checks a new application socket before switching (`src/frappe/dev_session.cr`) | `scripts/check frappe-project --dev`, `scripts/check dev-retirement` | |
| §2.3 First-Party Five SDKs | Absent | — | none | The generated README says `frappe add auth` is still being built. |
| §2.4 Barista, SaaS Kit, Roast Cloud | Absent | — | none | Funding outcomes are unverifiable. |
| §3 restore point and automatic rollback | Partial | A failing migration batch rolls back (`Caramel::Migrator`) | `spec/integration/database_spec.cr` | There is no restore point, health window or binary rollback. |

## RFC-0008 Poetic ergonomics

| Requirement | Status | Evidence | Coverage | Notes |
|---|---|---|---|---|
| §2.1 subject-verb-object domain macros (`team.invite`) | Absent | — | none | Requires changesets and jobs (RFC-0002, RFC-0003). |
| §2.2 sentence scopes with `preload` | Diverged | `Model.where(...).order(...).limit(...)` and `Model.find` | `spec/caramel/model_spec.cr`, `scripts/check model-compilation` | There are no named scopes or `preload`. |
| §2.3 semantic and temporal units; `retry_on` | Absent | Only Crystal's built-in `Time::Span` literals exist | none | |
| §2.4 Slang templates | Diverged | Compiled, escaping ECR (`src/caramel/view.cr`, `src/caramel/view/compiler.cr`) | `spec/caramel/view_spec.cr`, `scripts/check views` | Rationale: `docs/research/escaped-view-notes.md`. |
| §2.5 contract, handle and response actions | Implemented | `abstract struct Caramel::Action` with `contract`, `handle`, `page`, `morph`, `partials`, `json` and `stream`; contracts support nilable `Time`, bounds and defaults | `spec/caramel/action_spec.cr`, `spec/caramel/request_contract_spec.cr`, generated resource request specs | Adopted in commit `528c162`; the RFC's `Subscriptions::Pause` domain example is not shipped. |
| §2.6 terminal typography with remediation | Partial | Route-contract compile errors include a location and remediation; runtime errors render an HTML exception page | `scripts/check route-compilation`, `scripts/check runtime-diagnostics` | No N+1 diagnosis is possible because associations do not exist. |
| §3 `caramel expand` | Absent | Macros expand to ordinary Crystal, but no command shows the expansion | none | |
| §3 zero-allocation unit extensions | Absent | — | none | |

## Charter and invariant matrix

The charter names eight products. Three exist as code:
- Caramel Core in `src/caramel`;
- Latte in `src/latte` and `latte/macos`;
- Frappé in `src/frappe`.

SugarORM is replaced by the narrower `Caramel::Model`, and Corretto by ordinary Crystal specs. Cold Brew, Roast and Prose are absent. Scale and cost claims such as 100 million requests a day on a $40 server are unverifiable.

| Invariant (RFC Section 4) | Status | Notes |
|---|---|---|
| Core: no parameter-to-action contract drift via `Router.draw` | Implemented | Compile-time checks in `src/caramel/http/router.cr`. |
| SugarORM: zero N+1 queries via `NotLoaded \| Array(T)` | Absent | No associations exist. |
| Cold Brew: no dual-write loss via in-transaction enqueue | Absent | No queue exists. |
| Latte: instant iteration via Unix sockets and kqueue/inotify | Partial | Unix sockets are used, but watching is polled and compiled edits take seconds. |
| Frappé: low token overhead via stateless MRDP tools | Partial | MRDP covers only HTTP 422 errors; most commands call the daemon. |
| Corretto: no false confidence via real PostgreSQL branches | Diverged | Tests use a real per-site spec database, not branches. |
| Roast: one static binary of about 25 MB RSS, deployed over SSH | Absent | |
| Prose: fluent facades expand to pure changesets | Absent | |

## Repository blueprint (RFC Section 5)

| Planned | Actual |
|---|---|
| `ARCHITECTURE.md` | `docs/rfc.md` |
| `bin/caramel`, `bin/latte`, `bin/roast` | `bin/` is ignored build output from `scripts/build-frappe` and `scripts/build-latte`. It contains `frappe`, `latte`, `Latte.app` and `latte-port-relay`; there is no `roast`. |
| `src/core/**` | `src/caramel/`: `http/router.cr`, `http/request_context.cr`, `action.cr`, `contracts/request_contract.cr`, `hypermedia.cr`, `islands.cr` |
| `src/core/prose/**` | Absent |
| `src/orm/**` | `src/caramel/model.cr`, `src/caramel/migration.cr`; catalog, differ, linter, changeset, association and SQL modules are absent |
| `src/concurrency/**` | Streaming responses only (`src/caramel/response.cr`); the queue, worker and cache are absent |
| `src/dx/**` | `src/latte/`; the database brancher is absent |
| `src/agent/**` | `src/frappe/`; the manifest and Tier-1 checker are absent, and MRDP exists only in `RequestContract#to_mrdp` |
| `src/testing/**` | Absent; tests live in `spec/` and `scripts/checks/` |
| `src/ops/**` | Absent |
| `packages/**` (five SDKs) | Absent |
| Not in the blueprint | `templates/` (generated application and resources), `latte/macos/` (menu app, port relay), `tools/` (installers, toolchain definition), `vendor/` (bundled htmx) |
