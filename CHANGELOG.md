# Changelog

Caramel follows semantic versioning. During 0.x a minor release may break compatibility and a patch release never does ([ADR 0016](docs/decisions/0016-versioning-and-releases.md)). Write upgrade notes for the next release under Unreleased as bullets, with no heading of their own; `scripts/release` moves them into its section.

## Unreleased

- Public files are now streamed with `Content-Length`, `ETag` and `Last-Modified`, answer 304 to a current `If-None-Match` or `If-Modified-Since`, and carry `Cache-Control: public, max-age=31536000, immutable` when the name has a three-part version (`htmx-4.0.0.min.js`) and `no-cache` otherwise. `public/.well-known/` files are served, and any other path with a hidden segment (`/.env`, `/.something`) now goes to the router instead of answering 404 in the static layer, so a route such as `/.well-known/change-password` is reachable. A file that cannot be read answers a 500 with the security headers. Ranges are not supported ([ADR 0038](docs/decisions/0038-static-files.md)).
- Caramel now pins Crystal 1.22.1, which fixes io_uring event loop hangs, `OpenSSL::SSL::Options::ALL` and the `Content-Length` regressions of 1.22.0. Installing this release sets up a new toolchain directory, so its first builds start with an empty compiler cache. If you use the editor tools, run `frappe lsp install` again after installing. New applications declare `crystal: ">= 1.22.1"` in `shard.yml`, and `frappe build` compiles in `crystallang/crystal:1.22.1-alpine`.
- **Breaking for direct callers:** every request to the ops socket must carry the per-start key in `<socket>.key` (mode 0600, new at each start, removed at stop). Anything that talks to the socket without `APP ops` (`curl --unix-socket`, scrapers) must send `Authorization: Bearer $(cat SOCKET.key)`; Prometheus uses `authorization: credentials_file: SOCKET.key`. A request without the key answers 401. `ops console` prints a URL containing the key, and a TCP forward without that URL gets 401 ([ADR 0028](docs/decisions/0028-crema-production-access.md)).
- `frappe setup --no-migrate` installs dependencies and registers the site but leaves the development database unchanged, and prints that migrations were skipped and that `frappe migrate` applies them; `setup` without the flag still applies pending migrations ([ADR 0015](docs/decisions/0015-local-setup-and-latte-lifecycle.md)).
- With `caramel/tenancy` and no tenant bound, a cache key or PubSub channel name that starts with `t<id>:` now raises ArgumentError (inside `Caramel::Tenancy.without` it is allowed), and `Caramel::Cache.clear` deletes only the bound tenant's keys; with none bound it deletes only keys with no tenant prefix, and inside `without` every key. Wrap an app-wide clear in `without` ([ADR 0025](docs/decisions/0025-multi-tenancy.md)).
- `APP db roles` (and `DatabaseRoles.role`) now validate role and database names themselves, keep a password out of the `DO $` body, and the script fails before any grant when a role that already exists has SUPERUSER, CREATEDB, CREATEROLE, BYPASSRLS or REPLICATION. Run it with `psql -v ON_ERROR_STOP=1`; the role that runs it stays a member of both roles until you revoke them ([ADR 0032](docs/decisions/0032-application-production-contract.md)).
- `frappe lint` and new applications' `.ameba.yml` enable `Caramel/SourceTreeRead`, which reports a `File.read`, `File.open` or `Dir.glob` whose arguments contain `__DIR__`; a release artifact holds no source tree, so such a read fails only in production. Add the block to an existing application's `.ameba.yml` to adopt it. The deploy guide now says what the artifact holds and how to embed a file with `read_file`.
- A record is written as JSON only with the columns its schema's `json` line lists, such as `json :id, :title, :created_at, :updated_at`, where it wrote every column. Every model an action returns, or any other code writes as JSON, needs a `json` line; compilation fails without one and the error names the model. `frappe make resource` writes the line for new resources, listing the id, its fields and the timestamps, never the tenant column ([ADR 0007](docs/decisions/0007-sugarorm-schemas-changesets-preload.md)).
- `Caramel.content_security_policy` (in `config/application.cr`) changes the Content-Security-Policy of every response, `content_security_policy` in an action changes one response's copy, and `csp_nonce` adds a per-response nonce to `script-src` and `style-src`. A header an action sets itself is kept. `serve` now sends `Strict-Transport-Security: max-age=31536000` when `CARAMEL_ENV` is production or unset, so a proxy that added it can stop; it is never sent in development or test ([ADR 0037](docs/decisions/0037-response-security-headers.md)).
- At the first SIGTERM or SIGINT, `serve` now stops claiming jobs and ends every PubSub subscription, so a server-sent events stream ends instead of holding the process for the whole drain. `serve` and `work` give requests and jobs in flight `CARAMEL_SHUTDOWN_TIMEOUT` seconds (1 to 3600, default 25) and log what was still running when it passes; `work` used to wait without limit, so raise the setting for jobs that run longer than 25 s. A second signal exits 1 at once. A supervisor allows `CARAMEL_SHUTDOWN_TIMEOUT` plus 5 s before it kills a process ([ADR 0032](docs/decisions/0032-application-production-contract.md)).
- `frappe dev` no longer hands the development session cookie to any client on the machine. The gateway sets it only on a single-use link, `/__caramel/dev/sign-in?nonce=…`, that `frappe dev` prints as `Toolbar and inspector sign-in (single use): URL` (also with `--no-open`) and opens, and `frappe open` mints a new one while `frappe dev` runs. The inspector pages answer 403 without the cookie, the toolbar says `Not signed in`, and `/__caramel/dev/status` shows an unsigned client only `generation` and `state`; the build-error page stays public. Open a new link after restarting `frappe dev`; Latte.app's Open inspector item needs a signed-in browser ([ADR 0027](docs/decisions/0027-crema-tracing.md), [ADR 0029](docs/decisions/0029-latte-observes-local-sites.md)).

## 0.16.0 - 2026-10-15

### Upgrade notes

- `frappe db diff` now keeps an index or foreign key whose name SugarORM did not generate and prints a note, where it dropped every undeclared one. A changed index is built under a temporary `_swap` name, then the old index is dropped and the new one renamed, so a unique index is never missing. `belongs_to` takes `on_delete: :cascade`, `:restrict` or `:set_null` ([ADR 0007](docs/decisions/0007-sugarorm-schemas-changesets-preload.md)).
- `frappe migrate` commits each transactional migration with its own journal row instead of one shared transaction, so a failure no longer rolls back the migrations before it. A migration that hits `lock_timeout` rolls back and runs again after 1, 2 and 4 s; a fourth timeout stops `migrate` with `Migrator::LockTimedOut`, which names the migration ([ADR 0008](docs/decisions/0008-branch-and-diff-migrations.md)).
- `CARAMEL_POOL_SIZE` (1 to 32) and `CARAMEL_POOL_TIMEOUT` (1 to 300 seconds) set the connection pool of every command that opens one, which was fixed at 4 connections and a 5 s checkout wait. An invalid value exits 1 with one line naming it ([ADR 0032](docs/decisions/0032-application-production-contract.md)).
- Applications can use `BigDecimal`, `BigInt` and `BigRational` in every managed build: the toolchain now bundles GMP 6.3.0, and `frappe build` links it statically. Remove any `@[Link(ldflags: …)]` on `LibGMP` and any vendored `libgmp.a` an application added for this.
- The toolchain changed, so installing this release sets up a new toolchain directory and its first builds start with an empty compiler cache. If you use the editor tools, run `frappe lsp install` again after installing.

### Features

- **core:** read the pool size and checkout timeout from the environment (69d8d1f)

### Fixes

- **sugar_orm:** run each migration in its own transaction and retry lock timeouts (67e4238)
- **sugar_orm:** keep undeclared indexes and keys SugarORM did not name, and declare ON DELETE (6607cc6)
- **sugar_orm:** let a rebuilt unique index's swap converge, avoid swap-name collisions, and correct the :set_null wording (8d551d9)
- **sugar_orm:** never reuse a swap-named index with another definition (b65d20e)
- **frappe:** link GMP in every managed build, so applications can use BigDecimal (0e8e146)

## 0.15.0 - 2026-10-14

### Upgrade notes

- Every database connection now sets `statement_timeout` and `lock_timeout` when it opens, and the client's read timeout follows the statement timeout. `serve`, `work`, `seed`, `lint` and `drift` default to 30 s and 5 s; `migrate` defaults to no statement timeout and 5 s. A statement that ran longer than 30 s now fails with `canceling statement due to statement timeout`; raise `CARAMEL_STATEMENT_TIMEOUT` (whole seconds, 0 to 86400, 0 for none) for a process that needs longer, and `CARAMEL_MIGRATION_STATEMENT_TIMEOUT` or `CARAMEL_MIGRATION_LOCK_TIMEOUT` for `migrate` ([ADR 0032](docs/decisions/0032-application-production-contract.md)).
- A job whose process dies or loses its connection is failed on its third release instead of being redelivered forever: maintenance records `Caramel::ColdBrew::AbandonedJob` and calls the `on_failed` hooks, and `jobs retry` runs it again. Released runs no longer count against `retry_on` attempts. Run `frappe migrate` once: the framework migration `20260927000006` adds `caramel_jobs.releases` and takes a lock on every `caramel_jobs` partition, so run it while no job is running, or `migrate`'s 5 s lock timeout may refuse it (`CARAMEL_MIGRATION_LOCK_TIMEOUT` raises it) ([ADR 0019](docs/decisions/0019-cold-brew-status-hooks-and-work.md)).

### Features

- **core:** set statement and lock timeouts on every database connection (8bc3edf)

### Fixes

- **website:** wait only for the llms.txt an alias version gets (bd76902)
- **cold_brew:** fail a job whose process dies on three of its runs (d8c3e50)

## 0.14.0 - 2026-10-13

### Upgrade notes

- In an application that requires `caramel/sweet_talk`, a `SweetTalk::Refusal` that an action's `handle` does not rescue now answers 422 with its message under `_base`, shaped like a failed contract: `{"errors": {"_base": [message]}}` for JSON clients, `contract_failure_page` for browsers and htmx, and text starting `ERR INVALID:422` for other clients ([ADR 0034](docs/decisions/0034-sweettalk-at-the-web-boundary.md)). A `SweetTalk::Missing` answers 404. Neither is reported to Crema as an error any more. An action that rescues them itself is unchanged, and `SweetTalk::Boundary` still answers 500. Asking an aggregate for its id before `create`, or an event for its subject before it is emitted, now raises `NilAssertionError` instead of `SweetTalk::Missing`.
- A contract field may take a type that includes `Caramel::FieldValue(W)`, such as a SweetTalk value or an aggregate's id: `field quantity : Ordering::Quantity` binds as an `Int32`, and the value's refusal is the field's error ([ADR 0034](docs/decisions/0034-sweettalk-at-the-web-boundary.md)). `CARAMEL_FIELD_<NAME>` constants gain a sixth element, the declared type; a macro of your own that destructures exactly five elements must take six.
- `frappe make domain` also writes `.claude/skills/sweettalk/SKILL.md`, a Claude Code skill that lists the SweetTalk rules agents most often break, each linked to its section of the guide, when the application has none; it never replaces an existing one. An application made with 0.13.0 that already has a domain gets it with its next `frappe make domain`, or now, after upgrading, with `mkdir -p .claude/skills/sweettalk && cp lib/caramel/templates/skills/sweettalk/SKILL.md .claude/skills/sweettalk/`. Run the same copy after a later upgrade to refresh it. To point other agents at it, add the line new applications get after `Domain:` in AGENTS.md: `Domain rules: .claude/skills/sweettalk/SKILL.md, which frappe make domain writes`.
- Every page of the guides has a Markdown edition for agents at its address followed by `index.md`, listed in `https://caramelize.dev/docs/X.Y.Z/llms.txt`. `frappe agent-manifest` prints that address on a new `GUIDES:` line after `DOCS:`, so a tool that reads the manifest by line number finds the command lines one line later. Applications made earlier keep their AGENTS.md; to point agents at the Markdown edition, add the line new applications get after the documentation link: `Every page of it in Markdown: https://caramelize.dev/docs/VERSION/llms.txt`.
- SweetTalk stores a state of two or more words as `moves` spells it, and a lifecycle's `state` column has a CHECK constraint, `check_<table>_state_<8 hex digits>`, that admits only the states `moves` declares. 0.13.0 wrote `awaiting_payment` as `awaitingpayment`, so `finds state: :awaiting_payment` missed those rows, and they would break the new constraint.
  - First add a migration that respells them, one `UPDATE <table> SET state = '<state>' WHERE state = '<state without underscores>'` per table and such state, such as `UPDATE ordering_payments SET state = 'awaiting_payment' WHERE state = 'awaitingpayment'`, and migrate.
  - Then `frappe db diff` adds the constraint to every table with a lifecycle as `NOT VALID`, and validates it in the `_concurrently` migration. New rows are checked from the first migration.
  - If an existing row still holds any other text, `frappe migrate` stops and names the constraint, which stays `NOT VALID` until you fix those rows and migrate again.
  - A lifecycle whose constraint name would be longer than PostgreSQL's 63 bytes no longer compiles; the error names it. Give the context or the aggregate a shorter name. `renamed_from:` keeps the old table, and with it the long name, so it does not help here.
- A SweetTalk context can name a rule once with `specification Name, on: Aggregate, where: {…}, means: "…"`: it adds `aggregate.name?`, `Aggregate.all(satisfying: Name)` and `satisfying: Name` on `finds` and `counts` ([ADR 0035](docs/decisions/0035-sweettalk-specifications-queries-and-state-checks.md)). SugarORM gains `Query#where_condition`, which adds a prepared `SugarORM::Condition` in parentheses. Nothing changes until a domain uses them.
- SweetTalk queries can sort, limit and count: `finds verb(args), where: {…}, order: {attribute: :desc}, first: count`, with `where:` optional, and `counts verb(args), where: {…}`. A `finds` with a block narrows the live rows with SugarORM's `where`, `where_null`, `order_by`, `limit` and `offset` for a query `where:` cannot say. A projection declares `finds` and `counts` too, over its own attributes. This is additive: existing queries keep their SQL.
- A `finds` that names an unknown attribute or state, or a list of entities, now fails to compile even when nothing calls it; 0.13.0 waited for the first call. Fix such a query or remove it.
- `__sweettalk_rows` is no longer callable from outside its aggregate. Code that built aggregates from `Rows` queries outside a domain uses a `finds` with a block instead.
- SweetTalk: calling another context's service or module method, as in `Catalogue.price_of(tea)`, now counts as naming `Catalogue::` ([ADR 0036](docs/decisions/0036-sweettalk-strategic-design.md)). A context that does not follow Catalogue may make that call only inside `border Catalogue`; elsewhere it no longer compiles, so move the call into the border, or declare `follows: Catalogue`. In a border the call now draws a dependency edge, so two contexts whose borders call each other no longer compile: let one of them react to the other's events instead.
- SweetTalk: code in a context may name `Caramel::Outbound` or `HTTP::Client` only inside a border with a system outside the program, `border Cards, outside: "the card gateway we charge through" do … end`; elsewhere in a context it no longer compiles, and the error names the context. Move such calls into that border and call it from the context, as in `Cards.charge(…)`. Code outside a context, such as an action or a job, is unchanged. A context can also name its subdomain with `subdomain: :core`, `:supporting` or `:generic`, and list with `publishes` the names other contexts may use; nothing changes until a domain uses them.

### Breaking changes

- **core:** bind SweetTalk values and ids as contract fields (f1ba1c3)
- **sweettalk:** hold each lifecycle state in a PostgreSQL check (53b6511)
- **sweettalk:** sort, limit and count queries, with a block escape and projection queries (67fb310)
- **sweettalk:** publish a language and border outside systems (9118a35)

### Features

- **sweettalk:** answer refusals with 422 and missing aggregates with 404 (57d64b2)
- **website:** publish a Markdown edition of the guides for agents (6efd6bd)
- **frappe:** write a SweetTalk skill with frappe make domain (0b6037f)
- **sweettalk:** name a rule once with specification (3f6ce3a)
- **sweettalk:** mark a context's subdomain (3e68a84)

### Fixes

- **sweettalk:** store a two-word state as moves spells it (ac75117)

## 0.13.0 - 2026-10-12

### Upgrade notes

- A request may send at most 4,096 values and 128 files, and a multipart body's boundaries and part headers now count toward its size; more answers 413. Multipart files are stored only for a route whose contract has an `UploadedFile` field.
- Keyword `where` no longer takes a value that may be nil, such as a `String?` variable: it matched the rows whose column IS NULL whenever the value was nil. The call fails to compile with `…MayBeNil` in the error. Narrow the value first (`if token = contract.token`), or use the new `where_null(:column)` to match NULL. The literal `where(column: nil)` still works.
- `sudo scripts/install-local-integration apply` installs only a bundle that the user who ran `sudo` prepared, and refuses to run as root without `sudo`. The Swift build scripts keep their module cache in a private directory per user; a `CARAMEL_LATTE_SWIFT_CACHE` directory must be yours alone.
- An application can model its domain in SweetTalk, an opt-in language for Domain-Driven Design ([ADR 0030](docs/decisions/0030-sweettalk-domain-language.md), [ADR 0031](docs/decisions/0031-sweettalk-services-processes-and-richer-values.md) and [ADR 0033](docs/decisions/0033-sweettalk-multi-tenancy.md)). Nothing changes until it requires `caramel/sweet_talk`. SweetTalk is experimental until an application has run it in production: a minor release may still change the names it stores (its tables and their constraints, its job class names, its channels and its event metadata keys), and that release's upgrade notes will say how to move them. In a multi-tenant application, the domain names its tenant with `tenant App::Account` before its first context, and every context belongs to the tenant unless it says `central: true`.
- Crema has a `domain` span kind, which times SweetTalk's commands, factories and services. A sink or exporter that matches `Caramel::Crema::SpanKind` exhaustively must handle it.
- An application can start a SweetTalk domain with `frappe make domain NAME CONTEXT --means=TEXT`, such as `frappe make domain Shop Ordering --means="choosing teas and checking out"`. It adds `require "caramel/sweet_talk"` and `require "../app/domain/*"` to `config/application.cr`, and writes `app/domain/shop.cr` and `spec/domain/shop_spec.cr`. `frappe make tenancy` names the tenant in each domain in `app/domain/`. Applications generated before this release add the `Lint/UnusedArgument` exclusion for `app/domain/**` to their `.ameba.yml` by hand.

### Breaking changes

- **sugar_orm:** refuse a value that may be nil in keyword where (27f2e4e)

### Features

- **core:** let a proxy group connect to the application socket (44be218)
- **sweettalk:** add SweetTalk, an opt-in language for Domain-Driven Design (5909476)
- **sweettalk:** check value bounds and lengths in PostgreSQL (0a2beed)
- **sweettalk:** lock and upsert rows through SugarORM (b7f2569)
- **sweettalk:** refuse a program that also requires caramel/tenancy (5a6de73)
- **sweettalk:** arm a deadline for another span, and name a length range's real bounds (c9b8b5f)
- **sweettalk:** share a domain between tenants (ADR 0033) (ddbedf3)
- **crema:** time SweetTalk commands as domain spans (a1798b9)
- **sweettalk:** link events and jobs by cause and flow (0d25a98)
- **frappe:** make a SweetTalk domain (8c2ff55)

### Fixes

- **website:** publish only origin's main commit (6f5465e)
- **frappe:** name the artifact with exactly seven commit digits (6830340)
- **core:** bound what a request body can make the server hold (9bb970b)
- **latte:** keep the Swift module cache in a private directory per user (b86bf35)
- **latte:** install only the bundle of the user who ran sudo (32b0758)
- **sweettalk:** let an entity update only its own aggregate's row (9b6c0a7)
- **cold_brew:** refuse a late job alias that another job claims (8e1a133)

## 0.12.0 - 2026-10-11

### Upgrade notes

- Applications can run in production on Linux: `frappe build` writes a static linux/amd64 artifact, `serve` reads public files from `CARAMEL_ROOT`, runs without workers with `--no-workers` and finishes in-flight requests on SIGTERM, `APP jobs unknown` lists queued jobs a binary cannot run and `APP db roles` prints the role script (ADR 0032).
- On SIGTERM, `serve` now finishes in-flight requests for up to 25 s before it exits, and an open server-sent events stream holds it for the whole 25 s. Give a supervisor that stops `serve` at least 30 s.

### Features

- **core:** read public files from CARAMEL_ROOT (e033ab4)
- **core:** serve without Cold Brew workers (ccc98b7)
- **core:** finish in-flight requests on SIGTERM (5049929)
- **crema:** list queued jobs this binary cannot run (bf93952)
- **core:** print the database role script Latte runs (be568d1)
- **frappe:** build the Linux release artifact (d82e70b)

## 0.11.0 - 2026-10-10

### Upgrade notes

- Upgrade Caramel and Frappé together: the schema document `frappe db diff` reads is now version 3, because it carries CHECK constraints.
- SugarORM owns the CHECK constraints named `check_…`. `frappe db diff` drops a `check_…` constraint that no schema declares; any other CHECK constraint stays and is noted. Declare a hand-written `check_…` constraint, or rename it, before you diff.
- Two schemas that name one table no longer compile. Remove the duplicate or give one a different table.
- Run `shards update` so your application takes crystal-db 0.15.0 and crystal-pg 0.31.0.
- After a job is renamed or moved, name its old class with `renamed_from "Old::Name"` in the job. `work` and `migrate` now log a warning naming queued class names that no job claims.

### Features

- **core:** accept bounded array fields in request contracts (aed2c41)
- **sugar_orm:** store any field type through a codec (88e2540)
- **frappe:** make expand fall back to the enclosing macro call (204c9bc)
- **cold_brew:** keep queued jobs across a rename and report stranded class names (a3e0db1)
- **sugar_orm:** declare CHECK constraints in schemas (16bc348)
- **sugar_orm:** lock rows, upsert and version records (405885e)

### Fixes

- **website:** keep every release's guides and refuse a release the site does not name (db2a220)
- **website:** regenerate redirect aliases on every publish (d9fced6)
- **core:** report a repeated control key in the query as a duplicate field (100ee13)
- **sugar_orm:** make codec fields honest about inclusion validation and missing defaults (99089ab)
- **sugar_orm:** refuse two schemas that name one table (a4e194b)

## 0.10.0 - 2026-10-08

### Upgrade notes

- The inspector's request page shows each query as a card instead of a table row: the statement with one clause per line and coloured, and each bind listed beside its `$n`. Pointing at a placeholder or a bind lights up both. Copy SQL and Copy with values write the statement as it ran, as before.

### Features

- **crema:** show each query as a card with its SQL laid out and its binds listed (0bca849)
- **crema:** light up a placeholder and its value together (7de8e5d)

## 0.9.1 - 2026-10-08

### Fixes

- **latte:** let the latte-daemon check run the collector on a free port (b76b1f7)
- **core:** report a missing or unreachable database in one line (f0552b2)
- **frappe:** resolve an error outside a trace in frappe trace (ae30d7d)
- **latte:** start PostgreSQL after a crash left a stale postmaster.pid (96a0a7d)
- **core:** reserve the catalog key finalize (b706350)
- **latte:** replace DNS and proxy processes an earlier toolchain started (c2d9844)

## 0.9.0 - 2026-10-07

### Upgrade notes

- The development toolbar `frappe dev` adds to each page is redesigned: the route, status, time and query count read as separate parts and link to their place on the request's page in the inspector, flags (`error`, `slow`, `repeated queries`) are words, the recent-requests list opens above the bar and closes on Esc or a click outside, a count shows new requests, and it can be minimised to a dot. `` ` `` opens the list, `j` and `k` move through it, and **Copy for an agent** puts the request, its queries with their binds and its backtrace on the clipboard as Markdown.
- The inspector and the toolbar follow the system's light or dark appearance and share a **Theme: auto / light / dark** button's choice, which is kept in `localStorage` for the site. The production ops console follows the system appearance too, with its own button and its own stored choice, because it is served from another origin.
- The inspector's request page shows spans in recorded order, with those inside a view indented and coloured by kind, a time scale, and links from each query to its row. Each query has **Copy SQL** and **Copy with values**, which writes the bind values into the statement as PostgreSQL literals, ready for psql; a query keeps its first 20 binds, and a literal over 2,000 bytes (the value with its quotes) is not kept for copying; those placeholders stay as `$n` and the copy starts with a comment saying so. The Binds column shows values as the copy writes them (`42`, `'acme'`, `NULL`), and a `nil` bind is no longer recorded as `""`. The toolbar's links always land on a section: an empty one says nothing was recorded. Repeated queries are highlighted with their source, and a repeated `SELECT` suggests a preload; an error lists your backtrace frames with editor links.

### Features

- **frappe:** redesign the development toolbar (4645853)
- **frappe:** add light and dark themes to the development toolbar and inspector (c63943b)
- **frappe:** copy a query with its values, link the toolbar to the trace, theme the console (5f6ae00)

### Fixes

- **frappe:** style the development toolbar's link so it reads on the dark badge (a2a6c71)
- **crema:** refuse ops flags that were silently ignored (7765a13)
- **frappe:** copy queries with typed literals, harden the toolbar's keys and copy, guard trace.md (1012d4d)
- **crema:** show a nil bind as NULL on the error page (5f918f2)
- **crema:** copy E-strings correctly, keep every toolbar link on a section, show binds as copied, share one palette (5d56216)
- **crema:** leave a placeholder inside an identifier alone (fb38c3c)
- **crema:** act on the review of the copy follow-ups (30d1368)

## 0.8.0 - 2026-10-06

### Upgrade notes

- Crema, Caramel's observability ([ADR 0027](docs/decisions/0027-crema-tracing.md)), traces every routed request. Each response carries `X-Request-ID`, and a valid inbound `traceparent` continues the caller's trace. The application logs one canonical line per request through the `crema` log source, and `serve` and `work` set up logging themselves: JSON in production, text in development and test (`CARAMEL_LOG_FORMAT`, `LOG_LEVEL`). The old `request_id=… error_type=…` error line is gone; the `error` line carries `error_class` and `fingerprint` instead. `Caramel::DevelopmentError.response` now takes a `Caramel::Crema::ErrorReport`.
- Crema times every SQL statement, job, schedule run, outbound call, view render and cache read inside a trace. Statements start with a comment such as `/*action='App%3A%3ABooks%3A%3AShow'*/`; a job continues the trace of the request that enqueued it through the new `caramel_jobs.context` column (a framework migration, so run `frappe migrate`); and each database pool names itself in `application_name`. Cold Brew's worker, maintenance, scheduler and hook error lines are now `error` entries from the `crema` source. `Caramel::Database::Config` has an `application_name`. `SugarORM::Repo` has two private hooks, `observe` and `observe_checkout`, that `caramel/crema/sql` redefines. `dump value` is a development aid.
- `frappe dev` gets an inspector at `/__caramel/dev/inspector`, a toolbar on each page, richer error pages (editor links, the source, the request, queries and Copy as Markdown; set `CARAMEL_EDITOR`) and compile errors that link to the editor. `frappe traces`, `frappe trace REF` and `frappe errors` read what the session kept (`frappe errors` lists only what happened after the newest successful build, so a rebuild clears errors it fixed); MRDP gains the codes `RUNTIME` and `REPEATED_QUERY`. `frappe lint` and new applications' `.ameba.yml` enable `Caramel/Dump`, which reports a leftover `dump`; add it to an existing application's `.ameba.yml` to adopt it. The development gateway's status answers `latest`, and `Latte.app` has an Open inspector item.
- A running application opens an owner-only ops socket ([ADR 0028](docs/decisions/0028-crema-production-access.md)): `serve` next to its application socket, `work` only when `CARAMEL_OPS_SOCKET` names a path, `off` to disable. The binary is its own client: `ops status|requests|fibers|metrics|tail|errors|error|traces|trace|debug-token|console`. It serves Prometheus text, a read-only console, in-memory rings of errors (with redacted messages) and of failed, slow and debug traces, and signed debug tokens that record one person's requests. `APP jobs` (stats, failed, show, retry) and `APP db diagnose` (also `frappe db diagnose`) need only the database. `Caramel::CommandLine.with_database` is public for registered commands, and `Crema.command` adds application commands.
- `require "caramel/crema/recorder"` makes an application keep per-minute counts and latency histograms in `caramel_metrics`, read by `APP insights` and the ops console. New applications require it in `config/application.cr`; add the line after `require "caramel"` to adopt it, and run `frappe migrate` (a new framework migration creates the table). It stores aggregates only: route templates and parameterized SQL, never paths, bind values or messages.
- `require "caramel/crema/otlp"` exports traces as OTLP/HTTP JSON to the endpoint `OTEL_EXPORTER_OTLP_ENDPOINT` names, with the usual `OTEL_*` headers, service name and sampler variables ([ADR 0028](docs/decisions/0028-crema-production-access.md)). It does nothing without an endpoint. `Caramel::Outbound` calls carry the sampling decision in their `traceparent`.
- Latte's managed PostgreSQL preloads `pg_stat_statements` and `auto_explain` ([ADR 0029](docs/decisions/0029-latte-observes-local-sites.md)); the next start of an existing cluster restarts it once. Each site's development database gets `pg_stat_statements` in a `caramel_stats` schema, which `frappe db diagnose` reads and `frappe db dump` leaves out. No role is granted `pg_read_all_stats`, so a site's role sees statement text only for its own statements, and utility statements (such as `ALTER ROLE … PASSWORD`) are not tracked. `auto_explain` logs the text and plan of statements that take 250 ms or more to `postgres.log`; application statements carry placeholders, and no bind values are logged. The spec database is unchanged.
- Latte's control API gains version 2 ([ADR 0029](docs/decisions/0029-latte-observes-local-sites.md)): a site lists its development session's `errors` and `last_error`. Version 1 is still served and unchanged; Frappé, Corretto and Latte.app now ask for version 2, so run `latte stop` once after upgrading so the next command starts the new Latte. Latte.app shows error counts, counts new alerts beside its icon and posts macOS notifications for build failures and new errors; it opens the inspector from a site's menu.
- Latte's proxy writes a per-site access log to the site's log directory, and `frappe logs access [--follow]` prints it ([ADR 0029](docs/decisions/0029-latte-observes-local-sites.md)). Each line carries the application's `X-Request-Id`. `proxy.log` no longer carries access lines. The daemon restarts the proxy's configuration on its next reconcile, so no action is needed.
- Latte runs a local trace collector on `127.0.0.1:4318` ([ADR 0029](docs/decisions/0029-latte-observes-local-sites.md)). Point any service at it with `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318` and `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`; `frappe dev` sends its application's traces there, and the inspector and `frappe trace REF --md` show what other services did in the same trace under "Across services". If another program holds port 4318, Latte keeps running and `frappe services` shows the collector unavailable.
- `frappe new` writes an `AGENTS.md` that maps the application for coding agents, a `CLAUDE.md` that imports it, and a shorter `README.md`. Existing applications keep their files; copy `AGENTS.md` and `CLAUDE.md` from `templates/application` in the release source to adopt them.
- The `Caramel/ServiceNoun` lint message and description no longer cite the design RFC. The rule is unchanged.
- The release source no longer ships the design RFC, the research notes or the separate testing, views and editor-tools guides. The notes are in [caramel-notes](https://github.com/caramelizedev/caramel-notes), and the guides are on the website.
- An application can be multi-tenant ([ADR 0025](docs/decisions/0025-multi-tenancy.md)). Nothing changes until it runs `frappe make tenancy MODEL`, such as `frappe make tenancy Account`. That command adds the tenant's schema, migration, sign-up page and home page, `require "caramel/tenancy"` in `config/application.cr`, and a `tenant App::Account, by: :slug do … end` block in `config/routes.cr`. Resources generated after it belong to the tenant and live under `/SLUG`; `frappe make resource … --central` makes one every tenant shares. To make an existing populated table tenanted, follow the ADR's "Plugging in on existing data".
- `SugarORM::Catalog::ForeignKey` now holds `columns` and `references_columns` arrays instead of `column` and `references_column`, so a key may span several columns. The schema document an application prints for `frappe db diff` is now version 2: upgrade the application's Caramel and Frappé together.

### Breaking changes

- **sugar_orm:** support multi-column foreign keys (bc8ffb0)

### Features

- **core:** add opt-in multi-tenancy with caramel/tenancy (0d7ea4a)
- **frappe:** add make tenancy and tenant resources (76dfef8)
- **frappe:** give new applications AGENTS.md and a short README (3074d5a)
- **crema:** trace requests with request ids, traceparent and wide log lines (7a271cd)
- **crema:** instrument SQL, jobs, schedules, outbound calls, cache and views (5343a1b)
- **frappe:** add the development inspector, toolbar and richer error pages (fd8090e)
- **crema:** add the ops socket, console and production commands (5c458d7)
- **crema:** add the opt-in Postgres recorder (4ca9978)
- **crema:** add the opt-in OTLP trace exporter (6e05b8c)
- **latte:** collect query statistics in the managed PostgreSQL (7ddbcd8)
- **latte:** show error badges and notifications through control API v2 (938f4fe)
- **latte:** write per-site access logs (ea9d9b0)
- **latte:** collect local traces across sites (8fb4dd8)

### Fixes

- **sugar_orm:** drop undeclared foreign keys before column drops (cf0f186)
- **core:** match only tenant routes in a tenant, even for an empty block (dcbea8f)
- **frappe:** check tenant names' length and refuse a missing anchored file (7384b6d)
- **crema:** act on review findings: no log text, paths or statements in production surfaces (5822a1b)
- **latte:** narrow the collector's rescue and prove the statistics grant is gone (ed9d6af)
- **latte:** answer 400 to a collector body that is not an object (b3dab3d)

## 0.7.1 - 2026-10-02

### Upgrade notes

- A Caramel release that changes only its compiler and Shards launchers (`scripts/crystal`, `scripts/shards`) no longer installs a new managed toolchain. Installing it reuses your toolchain when its pinned tools match, including the one 0.7.0 installed, and writes the release's launchers into it, so compiler caches and editor tools survive the upgrade ([ADR 0015](docs/decisions/0015-local-setup-and-latte-lifecycle.md) §2).
- `scripts/crystal build` now runs the compiler without garbage collection (`GC_DONT_GC=1`). A warm 22-resource dev build is about 0.7 s faster, and each compile peaks about 125 MiB higher (about 1.35 GB at 22 resources). `run` and `spec` keep the collector, because the programs they start inherit the environment.

### Fixes

- **toolchain:** keep the managed toolchain when only its launchers change (d095022)
- **toolchain:** build without the compiler's garbage collector (f67c5df)

## 0.7.0 - 2026-10-02

### Upgrade notes

- Caramel can translate an application ([ADR 0024](docs/decisions/0024-internationalization.md)). Nothing changes until it runs `frappe make locale CODE`. That command adds `app/locales/en.cr`, `app/locales/CODE.cr` and the `caramel/i18n` lines in `config/application.cr`. Resources generated after it are translated, and `frappe translations` lists the keys each locale still lacks. Resources generated before it keep their English text until you replace it with `t.` calls.
- In an existing application, change `html lang: "en"` in `app/views/layouts/application.cr` to `html lang: Caramel.language`, as new applications have it. For a right-to-left locale, also add `dir: locale.dir`.
- `Caramel::Application::EXPIRED_FORM` is removed; use `Caramel::Wording.expired_form`, which a catalog can translate. Caramel's other messages now come from `Caramel::Wording` and `SugarORM::Wording`, with the same English text as before.
- In a translated application, contract and changeset errors are in the request's locale, in pages and in JSON `errors` alike, and so is the router's 404 body (`caramel.pages.not_found`). A changeset built outside a request, such as in a Cold Brew job, uses the default locale unless the job wraps its work in `Caramel::I18n.with(locale) { … }`.

### Breaking changes

- **core:** move Caramel's messages into Wording hooks (46f8dc4)

### Features

- **core:** add opt-in internationalization with caramel/i18n (6f4b2fd)
- **frappe:** add make locale, translations and translated resources (ad93ca8)

## 0.6.1 - 2026-10-01

### Fixes

- **sugar-orm:** compile each write's query once (5ff1208)
- **core:** compile action egress once instead of once per action (be9b969)

## 0.6.0 - 2026-10-01

### Upgrade notes

- Installing this release creates a new managed toolchain directory because its compiler and
  Shards launchers changed. The first builds start with an empty compiler cache. Editor users
  must run `frappe lsp install` again; rebuilding crystalline can take about 20 minutes.
- Corretto adds Blueprint-shaped `have_html` expectations and content blocks for `render_partial`. Existing matcher calls still work; `render_page` now requires a real doctype. See [testing HTML](docs/testing.md). Lexbor 3.6.4 is a development dependency: existing applications must add it under `development_dependencies` and refresh `shard.lock` before `frappe setup`; generated apps include the pin. Development installs build it with `cc` and `ar` (Apple Command Line Tools on macOS or `build-essential` on Debian/Ubuntu). Production installs omit the parser entirely.
- HTML expectations check numeric leaf values, accept conditional nested class arrays, and join direct text across comments. Unsupported leaf values raise with a `.to_s` remedy. Table rows and cells inside `hx-partial` envelopes use htmx's template parsing context. The [production case inventory](docs/research/corretto-html-testing.md) records the regression coverage and functional authoring exercises.

### Features

- **corretto:** add Blueprint-shaped HTML expectations (8decb18)

### Fixes

- **corretto:** cover production HTML and authoring edge cases (5fd7b51)

## 0.5.1 - 2026-09-30

### Fixes

- **latte:** let only exact matches make a service adoption ambiguous (71c3916)

## 0.5.0 - 2026-09-30

### Upgrade notes

- Routes now bind a JSON object where they answered 415 ([ADR 0020](docs/decisions/0020-action-ingress-and-json-bodies.md)). Each member must have its field's JSON type, and same-origin `fetch` sends the page's CSRF token as `X-CSRF-Token`. An application that reopened `Caramel::RequestInput` to parse JSON, or `Caramel::Application#handle` to receive a webhook, should delete the reopen: bind JSON through the contract, or declare `ingress body: :raw, limit: 256.kilobytes, csrf: false, authenticate: :signed?` on the webhook's action.
- `Caramel::RequestInput.read(request, max_form_bytes: n)` still works for 1 byte to 64 MiB, and raises `ArgumentError` outside that range. It is deprecated; pass the route's policy instead, as `Caramel::RequestInput.read(request, Caramel::Ingress.new(limit: n))`. A body that is neither a form nor a JSON object now answers 415 with "Expected a URL-encoded form, multipart form or JSON object".
- A custom `Caramel::Router::Dispatcher` must implement `match(request)` and `dispatch(context, match)`. Routers from `Caramel::Router.draw` already do.
- A form's `_method` override into a route whose `ingress` reads the body differently (another body, limit or CSRF setting) answers 405: that route is reached with its real method.
- The router now builds the action before its contract binds, so that an authenticator can run first. An action's own `initialize` therefore also runs for requests that end in a route 404 or a contract failure.
- Specs never received the development `.env` and still do not. Put test-only settings the application reads itself, such as `WEBHOOK_SECRET`, in a committed `.env.test`. `frappe new` now adds one.
- Instead of querying `caramel_jobs`, read a job with `Caramel::ColdBrew.status(id)` and learn of retries and failures with `on_retry_scheduled` and `on_failed` ([ADR 0019](docs/decisions/0019-cold-brew-status-hooks-and-work.md)). Jobs run at least once, so a job that calls another service should send it a stable identifier to deduplicate.
- To run workers without a web server, start the application binary with `work`, optionally with `--queues=`, `--concurrency=` and `--no-scheduler`.
- If `frappe dev` in an existing project stops on an asset output conflict, delete the public file it names to republish it from `app/assets`.
- `scripts/crystal`, the compiler launcher, changed, so installing this release sets up a new toolchain directory and its first builds start with an empty compiler cache. If you use the editor tools, run `frappe lsp install` again after installing; rebuilding crystalline takes up to about 20 minutes. In the first editor session afterwards, go to definition into Crystal's standard library can find nothing until you save the file once.
- Each compile now starts with a 1 GB heap, which uses about 250 MB more memory per compiler and saves most of its early garbage collections. Set `GC_INITIAL_HEAP_SIZE` yourself to choose another size.

### Features

- **frappe:** give specs the application's test settings from .env.test (cb7c730)
- **core:** run Cold Brew without HTTP with the work command (e0c83d2)
- **core:** report job status and call hooks after a failure is written (788b26c)
- **core:** let an action declare how its route reads the request (7740df1)
- **core:** send JSON, uploads and raw bodies from Corretto's client (3c8a9c1)
- **frappe:** mark URL resource fields with :url (0283a82)
- **core:** answer errors found after the contract with render_errors (2119c5d)
- **frappe:** generate only the resource actions --only names (ace706e)

### Fixes

- **frappe:** forward bodiless responses through the dev gateway (8a29a35)
- **core:** treat a closed stream as a disconnect, not an error (986c29b)
- **frappe:** record the assets a new project publishes (c918e2f)
- **release:** skip the migration probes when nothing they compile changed (f9cedf9)
- **core:** hold every ingress to the authenticator it names (b1f72b1)
- **checks:** verify the session's compiler and keep the lint proofs strict (8e17b8b)
- **frappe:** load the saved row in a request spec only when a check reads it (f82fe02)
- **core:** refuse a subtype ingress that drops its parent's authenticator (9fcafe0)
- **frappe:** run frappe dev's build for commands over the same sources (831971c)
- **corretto:** keep each worker's spec binary while its inputs are unchanged (58135a2)
- **corretto:** build spec binaries while the application migrates (b4f4fae)
- **core:** let crystal tool expand read the work command's options (e10b6dc)
- **core:** let frappe expand parse the work command's options again (551b9dc)
- **frappe:** make the dev build's semantic phase its Tier-1 type check (93365c6)
- **toolchain:** start the compiler with a 1 GB heap (e7d8ee6)
- **toolchain:** skip scripts/crystal's metadata rewrite when nothing changed (7b54d5a)
- **toolchain:** give each checkout program its own compiler cache root (ccaa191)

## 0.4.3 - 2026-09-29

### Fixes

- **frappe:** trim the dev loop's fixed waits (bf92bd3)
- **frappe:** build one-shot commands with the dev build's define (949f9e2)
- **corretto:** compile each worker from a stable entry file (87a508d)

## 0.4.2 - 2026-09-29

### Upgrade notes

- Caramel now pins Crystal 1.21.1, which fixes `Socket#connect` on macOS 26.7 and later and closes `HTTP::Server` request-smuggling and request-body decompression issues. Installing this release sets up a new toolchain directory, so its first builds start with an empty compiler cache.
- If you use the editor tools, run `frappe lsp install` again after installing: crystalline rebuilds against the new compiler, which takes up to about 20 minutes. In the first editor session afterwards, go to definition into Crystal's standard library can find nothing until you save the file once.
- New applications declare `crystal: ">= 1.21.1"` in `shard.yml`.

### Fixes

- **installations:** build a release's parts side by side (9ce40a9)
- **toolchain:** pin Crystal 1.21.1 for its macOS socket and HTTP server fixes (24f984f)

## 0.4.1 - 2026-09-29

### Fixes

- **release:** run the two migration probes side by side (061ec9a)

## 0.4.0 - 2026-09-28

### Upgrade notes

- `redirect_external` now refuses URLs with credentials (`https://user:pass@host/`) or whitespace, and `Caramel::Outbound` now refuses backslashes: both follow `Caramel::ExternalURL`, which `cs.validate_url(:field)` also applies when saving.
- A frappe older than 0.3.0 installs releases without their linter. If one installed this release, run the same `frappe installations install` command again to build it; `frappe doctor` names that command.

### Features

- **frappe:** build releases with their own script and finish installs that lack a linter (9e876d9)
- **frappe:** declare unique resource fields with :unique (fb7403f)
- **core:** share one external URL rule with cs.validate_url (951087f)

## 0.3.0 - 2026-09-28

### Upgrade notes

- Nothing in a 0.2.0 application has to change. To adopt the layout `frappe new` now generates, pass it the page: `ApplicationAction#layout` calls `Views::Layouts::Application.new(page, csrf_token).to_s`, and `app/views/layouts/application.cr` takes `(@page : Caramel::Page, @csrf_token : String)`, titles the document with `@page.title` and writes the body with `raw @page.html`.

### Features

- **frappe:** build the linter when installing a release (ae4c575)
- **core:** give layouts the page body as trusted HTML (68dda7e)
- **core:** build small fragments inline with markup (962db90)
- **core:** redirect to other sites deliberately with redirect_external (687c270)
- **frappe:** mark resource fields the server sets with :server (1b4392d)

## 0.2.0 - 2026-09-28

### Upgrade notes

- Views are Blueprint classes ([ADR 0018](docs/decisions/0018-blueprint-views.md)). ECR views, `Caramel::View.render`/`embed`, `view "..."` and `scripts/check views` are removed without a deprecation release; the only ECR applications were demos. To port an application:
  - rewrite each `app/views/**/*.html.ecr` as a class in `app/views/**/*.cr`: `app/views/<dir>/<name>.cr` defines `App::Views::<Dir>::<Name> < App::ApplicationView`, with typed inputs in `initialize` and markup in `private def blueprint`;
  - add `app/views/application_view.cr` (`abstract class App::ApplicationView < Caramel::View`, including `App::Paths`), as `frappe new` generates it;
  - in `config/application.cr`, require `../app/views/application_view` and then `../app/views/**` before the actions;
  - replace `view("x", a: b)` with `Views::X.new(b)`, for example `page "Books", Views::Books::Index.new(records)`, and the layout call in `ApplicationAction#layout` with `Views::Layouts::Application.new(page.title, Caramel::HTML::Safe.new(page.body), csrf_token).to_s`;
  - pass `csrf_token` to views that render forms;
  - in `.ameba.yml`, glob `app/**/*.cr` and exclude `app/views/**/*.cr` from `Lint/DebugCalls`.

### Breaking changes

- **core:** views are Blueprint classes (62b658d)

### Features

- **core:** add RFC-0008 byte sizes and Time#at_midnight (d8849ec)

### Fixes

- **latte:** adopt a postmaster another toolchain's build started (c327e36)
- **release:** read released framework migrations through a relative require (60cd6d3)
- **release:** refuse when the released tree cannot be extracted (dcdf2a7)

## 0.1.0 - 2026-09-28

### Features

- verify and document the isolated Caramel toolchain (17b3e3c)
- add Crystal runtime and PostgreSQL Bookshelf reference (93eb38f)
- add Latte managed services and native macOS controls (0fe4225)
- add typed models and browser form inputs (de32e39)
- add resumable private toolchain installer (72cc093)
- add Frappé project setup and typed resource generation (d59a914)
- add supervised development builds and local browser refresh (08e84be)
- add development exception pages and live project status (84f3aee)
- add Caramel Core routing, contracts and hypermedia (0488689)
- stream responses and adopt RFC-0008 action ergonomics (1ef1f46)
- **orm:** add SugarORM with derived, linted migrations and remove Caramel::Model (b47a9f1)
- **cold-brew,corretto:** add PostgreSQL jobs, PubSub and cache, and the Corretto test harness (8701c36)
- **latte:** watch with kqueue, type-check before building, clone branches with APFS and release guards on signals (13e1181)
- **frappe:** drive the CLI from one command table and add check, agent-manifest, db branch and expand (0a0a600)
- **latte,frappe:** find the toolchain through the checkout's .caramel-toolchain (6eae808)
- **installer:** default the toolchain root and record it for the checkout (0711fe5)
- **frappe:** put frappe and latte on PATH when registering a checkout (a5baa14)
- **latte,frappe:** start Latte on demand and stop it with latte stop (190be9b)
- **latte:** add an opt-in login item with latte service install (1bb41af)
- adopt the RFC-0008 rule set, with frappe lint and frappe format (ADR 0017) (2d1ca25)
- version the release and the Frappé–Latte contracts (ADR 0016) (2ba457c)
- generated apps depend on Caramel as a shard, with a one-call main (ADR 0016) (03a34e5)
- install tagged releases, run the newest Latte, and cut releases with scripts/release (ADR 0016) (d1673eb)

### Fixes

- record generated application edit-loop baselines (b5d8c2f)
- retire old development apps without blocking new builds (f4af078)
- **latte:** serve .localhost sites and never install Caddy CA trust (e8b8ef3)
- **core:** keep focus and island state across morphs (0268f72)
- **latte:** stop the daemon cleanly and tolerate Caddy restarts in checks (9389351)
- **cold-brew:** bound the security-definer partition functions (a2d2142)
- **latte:** let the port relay accept launchd's listening sockets (c7fd9d9)
- **frappe:** migrate new projects and report pending migrations once (76447d2)
- **latte:** say latte stop leaves services as they were (e11eaa8)
- **installer:** rerun the recorded toolchain when no root is given (cf7f5d6)
- **latte:** detach before loading the registry (1419cae)
- **installer:** validate the recorded pointer before reusing its toolchain (c0ff474)
- **frappe:** require the installed-releases reader where Latte starts (cf45846)
- close the ADR 0016 and 0017 audit findings (a4bc807)
