Guides / Current release

# Caramel today.

The supported APIs, development requirements, and current limits of Caramel 0.14.0.

## Upgrading to 0.14.0 {#c-release-upgrade-0140}

Upgrade Caramel and Frappé together. There are no framework migrations; these changes can need an edit.

- With `caramel/sweet_talk`, a `SweetTalk::Refusal` that an action’s `handle` does not rescue answers 422 with its message under `_base`, as a failed contract does, and a `SweetTalk::Missing` answers 404; neither is reported to Crema as an error. `SweetTalk::Boundary` still answers 500. Asking an aggregate for its id before `create`, or an event for its subject before it is emitted, raises `NilAssertionError` instead of `SweetTalk::Missing`.
- `CARAMEL_FIELD_<NAME>` constants gain a sixth element, the declared type, so a macro of your own that destructures exactly five must take six.
- A lifecycle’s `state` column now has a `CHECK` constraint, and a state of two or more words is stored as `moves` spells it. 0.13.0 stored `awaiting_payment` as `awaitingpayment`: first add a migration that respells such rows, such as `UPDATE ordering_payments SET state = 'awaiting_payment' WHERE state = 'awaitingpayment'`, and migrate, then run `frappe db diff`, which adds each constraint as `NOT VALID` and validates it in the `_concurrently` migration. `frappe migrate` stops, naming the constraint, while a row holds any other text. A lifecycle whose constraint name would pass PostgreSQL’s 63 bytes no longer compiles; shorten the context or the aggregate name.
- A `finds` that names an unknown attribute or state, or a list of entities, fails to compile even when nothing calls it. Code outside an aggregate can no longer call `__sweettalk_rows`; give the aggregate a `finds` with a block instead.
- Calling another context’s service, as in `Catalogue.price_of(tea)`, counts as naming `Catalogue::`: outside `border Catalogue` it compiles only where the context follows Catalogue, and two contexts whose borders call each other form a cycle. A context names `Caramel::Outbound` or `HTTP::Client` only inside a border with an outside system, `border Cards, outside: "…" do … end`.
- `frappe agent-manifest` prints a `GUIDES:` line after `DOCS:`, so a tool that reads the manifest by line number finds the commands one line later.
- For applications made earlier: to give agents the guides in Markdown, add `Every page of it in Markdown: https://caramelize.dev/docs/VERSION/llms.txt` after the documentation link in `AGENTS.md`. An application with a domain gets the SweetTalk skill with its next `frappe make domain`, or now with `mkdir -p .claude/skills/sweettalk && cp lib/caramel/templates/skills/sweettalk/SKILL.md .claude/skills/sweettalk/`, which also refreshes it after a later upgrade; add `Domain rules: .claude/skills/sweettalk/SKILL.md, which frappe make domain writes` after `Domain:` in `AGENTS.md`.

## Upgrading to 0.13.0 {#c-release-upgrade-0130}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; these changes can need an edit.

- Keyword `where` no longer takes a value that may be nil, such as a `String?` variable, because nil matched the rows whose column IS NULL. Narrow the value first, or use the new `where_null(:column)`; the literal `where(column: nil)` still works.
- A request may send at most 4,096 values and 128 files, and a multipart body’s boundaries and part headers count toward its size; more answers 413.
- A Crema sink or exporter that matches `Caramel::Crema::SpanKind` exhaustively must handle the new `domain` kind.
- `sudo scripts/install-local-integration apply` installs only a bundle that the user who ran `sudo` prepared.

## Upgrading to 0.12.0 {#c-release-upgrade-0120}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; one change can need an edit.

- On SIGTERM, `serve` now finishes in-flight requests for up to 25 s before it exits, and an open server-sent events stream holds it for the whole 25 s. Give a supervisor that stops `serve` at least 30 s.

## Upgrading to 0.11.0 {#c-release-upgrade-0110}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; these changes can need an edit.

- The schema document `frappe db diff` reads is now version 3, because it carries CHECK constraints.
- SugarORM owns the CHECK constraints named `check_…`. `frappe db diff` drops a `check_…` constraint that no schema declares; any other CHECK constraint stays and is noted. Declare a hand-written `check_…` constraint, or rename it, before you diff.
- Two schemas that name one table no longer compile. Remove the duplicate or give one a different table.
- Run `shards update` so your application takes crystal-db 0.15.0 and crystal-pg 0.31.0.
- After a job is renamed or moved, name its old class with `renamed_from "Old::Name"` in the job. `work` and `migrate` now log a warning naming queued class names that no job claims.

## Upgrading to 0.10.0 {#c-release-upgrade-0100}

Upgrade Caramel and Frappé together. There are no migrations and no breaking changes; the change is in the development tools.

- The inspector’s request page shows each query as a card instead of a table row: the statement with one clause per line and coloured, and each bind listed beside its `$n`. Pointing at a placeholder or a bind lights up both. **Copy SQL** and **Copy with values** still write the statement as it ran.

## Upgrading to 0.9.0 {#c-release-upgrade-090}

Upgrade Caramel and Frappé together. There are no migrations and no breaking changes; the changes are in the development tools.

- The development toolbar is redesigned: its route, status, time, query count and flags link to their place on the request’s page in the inspector, `` ` ``, `j` and `k` work from the keyboard, and **Copy for an agent** copies the request as Markdown.
- Each query on the inspector’s request page has **Copy SQL** and **Copy with values**. A `nil` bind is now recorded as `NULL` and shown bare in the Binds column; the text `NULL` stays quoted.
- The toolbar, the inspector and the production console follow the system’s light or dark appearance, with a Theme button to choose. The console keeps its own choice.
- The application binary’s `ops` commands now refuse a flag they would have ignored instead of dropping it silently.

## Upgrading to 0.8.0 {#c-release-upgrade}

Upgrade Caramel and Frappé together: the schema document `frappe db diff` reads is now version 2, and `SugarORM::Catalog::ForeignKey` holds `columns` and `references_columns` so a key can span several columns.

- Run `frappe migrate`. Two framework migrations add `caramel_jobs.context` and `caramel_metrics`.
- Run `latte stop` once if Latte is running, so the next command starts the new one. Frappé, Corretto and Latte.app now use Latte’s control API 2. The managed PostgreSQL restarts once to preload its statistics modules.
- To keep per-minute aggregates, add `require "caramel/crema/recorder"` after `require "caramel"` in `config/application.cr`. New applications already have it.
- Logging now sets itself up: JSON in production, text in development and test. The old `error_type` log line is gone; the `error` line carries `error_class` and `fingerprint`.

[What Crema adds →](https://caramelize.dev/docs/0.14.0/observability/index.md)

## Internationalization {#c-release-i18n}

Caramel has opt-in, typed translations. Run `frappe make locale CODE` to add Crystal catalogs and enable translated resource generation. Views and actions use `t` for messages and `l` for number and time formatting. Language selection supports a switch, optional URL prefixes, cookies, and browser preferences.

Contract and changeset errors, JSON error messages, and framework pages use the request’s locale. Missing translations fall back, and `frappe translations` reports what remains. Background jobs carry their language explicitly.

[Translate your application →](https://caramelize.dev/docs/0.14.0/internationalization/index.md)

## Runtime and local tools {#c-release-tools}

Caramel is a source-built Crystal framework. Its managed toolchain pins Crystal 1.21.1 and PostgreSQL 18. The local development workflow targets Apple Silicon macOS with Apple Command Line Tools. Frappé creates projects, generates resources, and supervises builds; Latte supplies managed services and named HTTPS.

Install from `v0.14.0` with the getting-started guide. An application’s `shard.lock` selects its framework release, and Frappé dispatches to the matching installation.

## Requests and responses {#c-release-requests}

Typed action contracts bind route and query values, URL-encoded forms, multipart uploads, and JSON objects. The default policy checks CSRF for writes and limits ordinary request input to 2 MiB; multipart uploads have a separate 64 MiB budget. Use per-action `ingress` for a custom limit, authenticated APIs, or exact raw webhook bytes.

Actions return HTML or JSON according to the request. `render_errors` handles errors found after contract binding. Blueprint views write typed HTML with escaped text and attributes; htmx partial responses update selected page regions.

## Data and resource generation {#c-release-data}

SugarORM provides typed schemas, changesets, queries, and explicit preloads. Derive a migration with `frappe db diff`, review it, and apply it with `frappe migrate`. `frappe make resource` generates application-owned models, changesets, actions, views, routes, migrations, and request specs.

Use `:server` for fields populated by the action, `:unique` for unique indexes and constraint checks, and `:url` for URL validation and inputs. `--only=create,show` generates a smaller action set; create and show are required, and edit needs new and update.

## Background work {#c-release-work}

Cold Brew stores jobs in PostgreSQL and supports transactional enqueueing, retry policies, durable status, retry/failure hooks, recurring schedules, PubSub, and cache. The application binary runs queues through `serve` or a worker-only `work` process with queue and concurrency options. External calls can repeat, so use a stable identifier for deduplication.

## Development and testing {#c-release-checks}

Corretto drives in-process application requests against isolated test databases. Its client sends forms, multipart uploads, JSON, or exact raw bodies. Blueprint-shaped `have_html` expectations inspect decoded rendered HTML; `render_partial` can check an envelope’s target, swap, and content together.

Generated applications pin Lexbor 3.6.4 under development dependencies. Development installs need cc, ar, and network access for the verified native parser source. Production installs omit the parser. Put application-owned test settings in committed `.env.test`; development `.env` does not reach specs.

**Terminal · application checks**

```bash
frappe check
frappe corretto
frappe lint
```

## Multi-tenancy {#c-release-tenancy}

An application can be multi-tenant. `frappe make tenancy MODEL` adds the tenant schema, sign-up and home pages, and a `tenant` block in the routes; resources generated afterwards belong to the tenant, and `--central` makes one every tenant shares.

[Add tenants →](https://caramelize.dev/docs/0.14.0/multi-tenancy/index.md)

## Domain-Driven Design {#c-release-sweettalk}

An application can model its domain in SweetTalk, an opt-in language whose contexts, values, aggregates, events, policies, projections and processes expand into SugarORM and Cold Brew. `frappe make domain NAME CONTEXT --means=TEXT` starts one in `app/domain/`, and writes a skill that gives agents its rules. 0.14.0 answers a refusal from an action with 422 and binds values and ids as contract fields, names a rule once with `specification`, sorts, limits and counts queries, holds each lifecycle’s states in a PostgreSQL check, and adds a context’s `subdomain:`, its published language and borders with systems outside the program. The guide maps each Domain-Driven Design pattern to its word. SweetTalk is experimental: until an application has run it in production, a minor release may change the names it stores, and its upgrade notes will say how to move them.

[Speak the domain’s language →](https://caramelize.dev/docs/0.14.0/sweettalk/index.md)

## Observability {#c-release-observability}

Every routed request, job and schedule run gets a request id, a trace and one canonical log line. In development, `frappe dev` adds an inspector, a toolbar, richer error pages and the `frappe traces`, `trace` and `errors` commands. In production, an owner-only ops socket serves status, Prometheus text, recent errors and a console; the recorder and the OTLP exporter are opt-in. Latte adds statement statistics, menu-bar error counts and notifications, per-site access logs and a local trace collector on `127.0.0.1:4318`.

[Read the observability guide →](https://caramelize.dev/docs/0.14.0/observability/index.md)

## Current limits {#c-release-limits}

File upload parsing is available, but the cookbook still needs a complete storage and cleanup example. A complete production deployment recipe, optional authentication generator, smaller individual generators, a Frappé extension point for custom commands, and a consumer installer remain unfinished. An application can add commands to its own binary with `Caramel::Crema.command`. Draft recipes identify application examples that still need end-to-end validation.

[Caramel 0.14.0 source release ↗](https://github.com/caramelizedev/caramel/releases/tag/v0.14.0)

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Build your first application →](https://caramelize.dev/docs/0.14.0/getting-started/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/releases/
