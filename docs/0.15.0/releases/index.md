Guides / Current release

# Caramel today.

What to do when you upgrade an application to Caramel 0.15.0, release by release since 0.8.0, and what the release supports and still lacks.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Covers | Upgrade notes from 0.8.0 to 0.15.0, what the release supports and its current limits |
| Needs | An application whose `shard.lock` pins an earlier release, and the [machine setup of your first application](https://caramelize.dev/docs/0.15.0/getting-started/index.md) |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## The guide in three stages {#c-releases-map}

20 sections · read in order the first time

- **1 · Upgrade notes**

  - [Upgrading to 0.15.0](#c-releases-upgrade-0150)
  - [Upgrading to 0.14.0](#c-releases-upgrade-0140)
  - [Upgrading to 0.13.0](#c-releases-upgrade-0130)
  - [Upgrading to 0.12.0](#c-releases-upgrade-0120)
  - [Upgrading to 0.11.0](#c-releases-upgrade-0110)
  - [Upgrading to 0.10.0](#c-releases-upgrade-0100)
  - [Upgrading to 0.9.0](#c-releases-upgrade-090)
  - [Upgrading to 0.8.0](#c-releases-upgrade-080)
  - [Earlier releases](#c-releases-earlier)
- **2 · Supported today**

  - [Runtime and local tools](#c-releases-tools)
  - [Requests and responses](#c-releases-requests)
  - [Data and resource generation](#c-releases-data)
  - [Background work](#c-releases-work)
  - [Development and testing](#c-releases-checks)
  - [Internationalization](#c-releases-i18n)
  - [Multi-tenancy](#c-releases-tenancy)
  - [Domain-Driven Design](#c-releases-sweettalk)
  - [Observability](#c-releases-observability)
  - [Production](#c-releases-production)
- **3 · Limits**

  - [Current limits](#c-releases-limits)

Each upgrade section is written from the release’s entry in [CHANGELOG.md ↗](https://github.com/caramelizedev/caramel/blob/v0.15.0/CHANGELOG.md): what to run, what to edit, and what changes without an edit. Upgrade one release at a time and run the proof at the end after each.

Upgrade notes

## Upgrading to 0.15.0 {#c-releases-upgrade-0150}

Upgrade Caramel and Frappé together. Run `frappe migrate` once for a framework migration; these changes can need an edit.

- Every database connection sets `statement_timeout` and `lock_timeout` when it opens, and the client’s read timeout follows the statement timeout, 5 seconds behind it. `serve`, `work`, `seed`, `lint` and `drift` default to 30 s and 5 s; `migrate` defaults to no statement timeout and 5 s. A statement that ran longer than 30 s now fails with `canceling statement due to statement timeout`. Raise `CARAMEL_STATEMENT_TIMEOUT` or `CARAMEL_LOCK_TIMEOUT` for a process that needs longer, and `CARAMEL_MIGRATION_STATEMENT_TIMEOUT` or `CARAMEL_MIGRATION_LOCK_TIMEOUT` for `migrate`: whole seconds, 0 to 86400, 0 for none. [The Crema reference lists the variables →](https://caramelize.dev/docs/0.15.0/crema/index.md)
- A job whose process dies or loses its connection is failed on its third release instead of being redelivered forever: maintenance records `Caramel::ColdBrew::AbandonedJob`, calls the `on_failed` hooks, and `jobs retry` runs it again. Released runs no longer count against `retry_on` attempts.
- The framework migration `20260927000006` adds `caramel_jobs.releases` and takes a lock on every `caramel_jobs` partition. Run `frappe migrate` while no job is running, or `migrate`’s 5 s lock timeout may refuse it; `CARAMEL_MIGRATION_LOCK_TIMEOUT` raises it.

## Upgrading to 0.14.0 {#c-releases-upgrade-0140}

Upgrade Caramel and Frappé together. There are no framework migrations; an application with a SweetTalk domain adds one of its own, and these changes can need an edit.

- With `caramel/sweet_talk`, a `SweetTalk::Refusal` that an action’s `handle` does not rescue answers 422 with its message under `_base`, shaped like a failed contract: `{"errors": {"_base": [message]}}` for JSON clients, the contract failure page for browsers and htmx, and text starting `ERR INVALID:422` for other clients. A `SweetTalk::Missing` answers 404. Neither is reported to Crema as an error. An action that rescues them itself is unchanged, and `SweetTalk::Boundary` still answers 500. Asking an aggregate for its id before `create`, or an event for its subject before it is emitted, raises `NilAssertionError` instead of `SweetTalk::Missing`.
- A contract field may take a SweetTalk value or an aggregate’s id: `field quantity : Ordering::Quantity` binds as an `Int32`, and the value’s refusal is the field’s error. `CARAMEL_FIELD_<NAME>` constants gain a sixth element, the declared type, so a macro of your own that destructures exactly five must take six.
- A lifecycle’s `state` column has a `CHECK` constraint named `check_<table>_state_<8 hex digits>`, and a state of two or more words is stored as `moves` spells it. 0.13.0 stored `awaiting_payment` as `awaitingpayment`: first add a migration that respells such rows, such as `UPDATE ordering_payments SET state = 'awaiting_payment' WHERE state = 'awaitingpayment'`, and migrate, then run `frappe db diff`, which adds each constraint as `NOT VALID` and validates it in the `_concurrently` migration. `frappe migrate` stops, naming the constraint, while a row holds any other text; the constraint stays `NOT VALID` until you fix those rows and migrate again. A lifecycle whose constraint name would pass PostgreSQL’s 63 bytes no longer compiles; give the context or the aggregate a shorter name, since `renamed_from:` keeps the old table and its long name.
- A `finds` that names an unknown attribute or state, or a list of entities, fails to compile even when nothing calls it. Code outside an aggregate can no longer call `__sweettalk_rows`; give the aggregate a `finds` with a block instead.
- Calling another context’s service, as in `Catalogue.price_of(tea)`, counts as naming `Catalogue::`: outside `border Catalogue` it compiles only where the context follows Catalogue. Move the call into the border, or declare `follows: Catalogue`. In a border the call draws a dependency edge, so two contexts whose borders call each other no longer compile: let one of them react to the other’s events instead. A context names `Caramel::Outbound` or `HTTP::Client` only inside a border with an outside system, `border Cards, outside: "…" do … end`.
- Additive, nothing to edit: `specification` names a rule once, `finds` and `counts` sort, limit and count, a context names its `subdomain:` and what it `publishes`. [The SweetTalk guide lists them →](https://caramelize.dev/docs/0.15.0/sweettalk/index.md)
- `frappe agent-manifest` prints a `GUIDES:` line after `DOCS:`, so a tool that reads the manifest by line number finds the commands one line later.
- For applications made earlier: to give agents the guides in Markdown, add `Every page of it in Markdown: https://caramelize.dev/docs/VERSION/llms.txt` after the documentation link in `AGENTS.md`. An application with a domain gets the SweetTalk skill with its next `frappe make domain`, or now with `mkdir -p .claude/skills/sweettalk && cp lib/caramel/templates/skills/sweettalk/SKILL.md .claude/skills/sweettalk/`, which also refreshes it after a later upgrade; add `Domain rules: .claude/skills/sweettalk/SKILL.md, which frappe make domain writes` after `Domain:` in `AGENTS.md`.

## Upgrading to 0.13.0 {#c-releases-upgrade-0130}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; one call stops compiling, and these changes can need an edit.

- Keyword `where` no longer takes a value that may be nil, such as a `String?` variable, because nil matched the rows whose column IS NULL. The call fails to compile with `…MayBeNil` in the error. Narrow the value first (`if token = contract.token`), or use the new `where_null(:column)`; the literal `where(column: nil)` still works.
- A request may send at most 4,096 values and 128 files, and a multipart body’s boundaries and part headers count toward its size; more answers 413. Multipart files are stored only for a route whose contract has an `UploadedFile` field.
- A Crema sink or exporter that matches `Caramel::Crema::SpanKind` exhaustively must handle the new `domain` kind.
- `sudo scripts/install-local-integration apply` installs only a bundle that the user who ran `sudo` prepared, and refuses to run as root without `sudo`. A `CARAMEL_LATTE_SWIFT_CACHE` directory must be yours alone.
- SweetTalk arrives, experimental, and nothing changes until an application requires `caramel/sweet_talk`. `frappe make domain NAME CONTEXT --means=TEXT` starts a domain; a multi-tenant application names its tenant with `tenant App::Account` before its first context. Applications generated before this release add the `Lint/UnusedArgument` exclusion for `app/domain/**` to their `.ameba.yml` by hand, as `lib/caramel/templates/application/.ameba.yml` has it.

## Upgrading to 0.12.0 {#c-releases-upgrade-0120}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; one change can need an edit.

- On SIGTERM, `serve` now finishes in-flight requests for up to 25 s before it exits, and an open server-sent events stream holds it for the whole 25 s. Give a supervisor that stops `serve` at least 30 s.
- Applications can run in production on Linux: `frappe build` writes a static linux/amd64 artifact, `serve` reads public files from `CARAMEL_ROOT` and runs without workers with `--no-workers`, `APP jobs unknown` lists queued jobs a binary cannot run and `APP db roles` prints the role script. Nothing to edit. [The Production guide puts them in order →](https://caramelize.dev/docs/0.15.0/deployment/index.md)

## Upgrading to 0.11.0 {#c-releases-upgrade-0110}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; these changes can need an edit.

- The schema document `frappe db diff` reads is now version 3, because it carries CHECK constraints.
- SugarORM owns the CHECK constraints named `check_…`. `frappe db diff` drops a `check_…` constraint that no schema declares; any other CHECK constraint stays and is noted. Declare a hand-written `check_…` constraint, or rename it, before you diff.
- Two schemas that name one table no longer compile. Remove the duplicate or give one a different table.
- Run `shards update` so your application takes crystal-db 0.15.0 and crystal-pg 0.31.0.
- After a job is renamed or moved, name its old class with `renamed_from "Old::Name"` in the job. `work` and `migrate` now log a warning naming queued class names that no job claims.

## Upgrading to 0.10.0 {#c-releases-upgrade-0100}

Upgrade Caramel and Frappé together. There are no migrations and no breaking changes; the change is in the development tools.

- The inspector’s request page shows each query as a card instead of a table row: the statement with one clause per line and coloured, and each bind listed beside its `$n`. Pointing at a placeholder or a bind lights up both. **Copy SQL** and **Copy with values** still write the statement as it ran.

## Upgrading to 0.9.0 {#c-releases-upgrade-090}

Upgrade Caramel and Frappé together. There are no migrations and no breaking changes; the changes are in the development tools.

- The development toolbar is redesigned: its route, status, time, query count and flags link to their place on the request’s page in the inspector, `` ` ``, `j` and `k` work from the keyboard, and **Copy for an agent** copies the request as Markdown.
- Each query on the inspector’s request page has **Copy SQL** and **Copy with values**. A query keeps its first 20 binds, and a literal over 2,000 bytes is not kept for copying: those placeholders stay as `$n` and the copy starts with a comment saying so. A `nil` bind is now recorded as `NULL` and shown bare in the Binds column; the text `NULL` stays quoted.
- The toolbar, the inspector and the production console follow the system’s light or dark appearance, with a Theme button to choose. The console keeps its own choice.
- The application binary’s `ops` commands now refuse a flag they would have ignored instead of dropping it silently.

## Upgrading to 0.8.0 {#c-releases-upgrade-080}

Upgrade Caramel and Frappé together. The schema document `frappe db diff` reads is now version 2, and `SugarORM::Catalog::ForeignKey` holds `columns` and `references_columns` so a key can span several columns. Two framework migrations and these edits apply.

- Run `frappe migrate`. Two framework migrations add `caramel_jobs.context` and `caramel_metrics`.
- Run `latte stop` once if Latte is running, so the next command starts the new one. Frappé, Corretto and Latte.app now use Latte’s control API 2. The managed PostgreSQL restarts once to preload `pg_stat_statements` and `auto_explain`.
- To keep per-minute aggregates, add `require "caramel/crema/recorder"` after `require "caramel"` in `config/application.cr`. New applications already have it.
- Add `Caramel/Dump` to an existing application’s `.ameba.yml`, as new applications have it, so `frappe lint` reports a leftover `dump`.
- Logging now sets itself up: JSON in production, text in development and test. The old `error_type` log line is gone; the `error` line carries `error_class` and `fingerprint`. `Caramel::DevelopmentError.response` now takes a `Caramel::Crema::ErrorReport`; `Caramel::Database::Config` gains `application_name`, and `SugarORM::Repo` the private hooks `observe` and `observe_checkout`, which `caramel/crema/sql` redefines.
- To adopt the agent files, copy `AGENTS.md` and `CLAUDE.md` from `lib/caramel/templates/application`; existing applications keep their own.
- Opt in as you need: `require "caramel/crema/otlp"` exports traces to the endpoint `OTEL_EXPORTER_OTLP_ENDPOINT` names; the ops socket opens beside `serve`, and for `work` when `CARAMEL_OPS_SOCKET` names a path; `frappe logs access` prints the site’s access log; `frappe make tenancy MODEL` makes the application multi-tenant.

[What Crema adds →](https://caramelize.dev/docs/0.15.0/observability/index.md)

## Earlier releases {#c-releases-earlier}

The notes start at 0.8.0, the release that first put its upgrade steps on this page. Each release’s guides stay published at `/docs/VERSION/` from 0.4.0 on, and CHANGELOG.md holds every release’s notes. The ones before 0.8.0 that still need an edit: 0.7.0 changes `html lang: "en"` in `app/views/layouts/application.cr` to `html lang: Caramel.language` and replaces `Caramel::Application::EXPIRED_FORM` with `Caramel::Wording.expired_form`; 0.6.0 adds Lexbor 3.6.4 under `development_dependencies`; 0.5.0 binds JSON bodies through the contract and gives specs a committed `.env.test`; 0.4.2 pins Crystal 1.21.1.

Supported today

## Runtime and local tools {#c-releases-tools}

Caramel is a source-built Crystal framework with a managed toolchain; the versions it pins and the machine it develops on are stated once, in [Your first application](https://caramelize.dev/docs/0.15.0/getting-started/index.md). Frappé creates projects, generates resources and supervises builds; Latte supplies managed services and named HTTPS. An application’s `shard.lock` selects its framework release, and Frappé dispatches to the matching installation; `frappe installations install VERSION` installs another release beside this one.

[Caramel 0.15.0 source release ↗](https://github.com/caramelizedev/caramel/releases/tag/v0.15.0)

## Requests and responses {#c-releases-requests}

Typed action contracts bind route and query values, URL-encoded forms, multipart uploads, and JSON objects. The default policy checks CSRF for writes and limits ordinary request input to 2 MiB; multipart uploads have a separate 64 MiB budget. Use per-action `ingress` for a custom limit, authenticated APIs, or exact raw webhook bytes.

Actions return HTML or JSON according to the request. `render_errors` handles errors found after contract binding. Blueprint views write typed HTML with escaped text and attributes; htmx partial responses update selected page regions.

## Data and resource generation {#c-releases-data}

SugarORM provides typed schemas, codecs for any field type, changesets, queries, explicit preloads, row locks, upserts, version columns and CHECK constraints. Derive a migration with `frappe db diff`, review it, and apply it with `frappe migrate`; `frappe seed` runs `db/seeds.cr`. `frappe make resource` generates application-owned models, changesets, actions, views, routes, migrations, and request specs.

Use `:server` for fields populated by the action, `:unique` for unique indexes and constraint checks, and `:url` for URL validation and inputs. `--only=create,show` generates a smaller action set; create and show are required, and edit needs new and update.

[Read the SugarORM reference →](https://caramelize.dev/docs/0.15.0/sugarorm/index.md)

## Background work {#c-releases-work}

Cold Brew stores jobs in PostgreSQL and supports transactional enqueueing, retry policies, durable status, retry and failure hooks, renamed jobs, recurring schedules, PubSub, and cache. A job whose process died on three of its runs fails as `Caramel::ColdBrew::AbandonedJob` and can be retried. The application binary runs queues through `serve` or a worker-only `work` process with queue and concurrency options. External calls can repeat, so use a stable identifier for deduplication.

[Read the Cold Brew reference →](https://caramelize.dev/docs/0.15.0/cold-brew/index.md)

## Development and testing {#c-releases-checks}

Corretto drives in-process application requests against isolated test databases. Its client sends forms, multipart uploads, JSON, or exact raw bodies. Blueprint-shaped `have_html` expectations inspect decoded rendered HTML; `render_partial` can check an envelope’s target, swap, and content together.

Generated applications pin Lexbor 3.6.4 under development dependencies. Development installs need cc, ar, and network access for the verified native parser source. Production installs omit the parser. Put application-owned test settings in committed `.env.test`; development `.env` does not reach specs.

Every page of these guides has a Markdown edition at its address followed by `index.md`, listed in `https://caramelize.dev/docs/0.15.0/llms.txt`, and `frappe agent-manifest` prints that address on its `GUIDES:` line.

## Internationalization {#c-releases-i18n}

Caramel has opt-in, typed translations. Run `frappe make locale CODE` to add Crystal catalogs and enable translated resource generation. Views and actions use `t` for messages and `l` for number and time formatting. Language selection supports a switch, optional URL prefixes, cookies, and browser preferences.

Contract and changeset errors, JSON error messages, and framework pages use the request’s locale. Missing translations fall back, and `frappe translations` reports what remains. Background jobs carry their language explicitly.

[Translate your application →](https://caramelize.dev/docs/0.15.0/internationalization/index.md)

## Multi-tenancy {#c-releases-tenancy}

An application can be multi-tenant. `frappe make tenancy MODEL` adds the tenant schema, sign-up and home pages, and a `tenant` block in the routes; resources generated afterwards belong to the tenant, and `--central` makes one every tenant shares.

[Add tenants →](https://caramelize.dev/docs/0.15.0/multi-tenancy/index.md)

## Domain-Driven Design {#c-releases-sweettalk}

An application can model its domain in SweetTalk, an opt-in language whose contexts, values, aggregates, events, policies, projections and processes expand into SugarORM and Cold Brew. `frappe make domain NAME CONTEXT --means=TEXT` starts one in `app/domain/` and writes a skill that gives agents its rules. Since 0.14.0 a refusal answers 422 from an action, values and ids bind as contract fields, and a lifecycle’s states are held in a PostgreSQL check. The guide maps each Domain-Driven Design pattern to its word and states its experimental status; the Box Office path builds one domain end to end.

[Speak the domain’s language →](https://caramelize.dev/docs/0.15.0/sweettalk/index.md) [Build a box office →](https://caramelize.dev/docs/0.15.0/box-office/index.md)

## Observability {#c-releases-observability}

Every routed request, job and schedule run gets a request id, a trace and one canonical log line. In development, `frappe dev` adds an inspector, a toolbar, richer error pages and the `frappe traces`, `trace` and `errors` commands. In production, an owner-only ops socket serves status, Prometheus text, recent errors and a console; the recorder and the OTLP exporter are opt-in. Latte adds statement statistics, menu-bar error counts and notifications, per-site access logs and a local trace collector on `127.0.0.1:4318`.

[Read the observability guide →](https://caramelize.dev/docs/0.15.0/observability/index.md)

## Production {#c-releases-production}

An application runs in production on Linux: `frappe build` writes a static linux/amd64 artifact, `serve --no-workers` and `work` are the process roles, `GET /health` answers readiness, SIGTERM drains for up to 25 s, `APP db roles` prints the role script and `APP jobs unknown` checks the queue before cutover. Every connection carries the statement and lock timeouts of 0.15.0.

[Read the Production guide →](https://caramelize.dev/docs/0.15.0/deployment/index.md)

Limits

## Current limits {#c-releases-limits}

- Caramel ships no command that provisions servers or deploys; `frappe build` ends at the artifact.
- No generator for authentication: the sessions recipe shows the tables and actions to write by hand.
- Multipart files are parsed and bounded, but no recipe yet stores a file and removes it; `storage/` is generated empty.
- Frappé has no extension point for commands of its own; an application adds commands to its binary with `Caramel::Crema.command`.
- Installing a release still starts from a Git checkout of the framework: `frappe installations install VERSION` exists once one release is registered, and there is no installer for a machine without one.
- Recipes labelled Draft are written against 0.15.0 and not run end to end; the cookbook marks each.
- SweetTalk is experimental until an application has run it in production.

Prove it

## Check an upgraded application {#c-releases-prove}

**Terminal · inside the application, after each release**

```bash
frappe migrate
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe migrate` ends with `The database matches the declared schema.`, `frappe check` exits 0, `frappe corretto` ends with `Corretto: N of N workers passed` and `frappe lint` exits 0.

[Take the application to production →](https://caramelize.dev/docs/0.15.0/deployment/index.md)

Caramel 0.15.0 · https://caramelize.dev/docs/0.15.0/releases/
