Guides / Current release

# Caramel today.

What to do when you upgrade an application to Caramel 0.20.0, release by release since 0.8.0, and what the release supports and still lacks.

| Contract | Value |
| --- | --- |
| Release | 0.20.0 |
| Covers | Upgrade notes from 0.8.0 to 0.20.0, what the release supports and its current limits |
| Needs | An application whose `shard.lock` pins an earlier release, and the [machine setup of your first application](https://caramelize.dev/docs/0.20.0/getting-started/index.md) |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## The guide in three stages {#c-releases-map}

26 sections · read in order the first time

- **1 · Upgrade notes**

  - [Upgrading to 0.20.0](#c-releases-upgrade-0200)
  - [Upgrading to 0.19.0](#c-releases-upgrade-0190)
  - [Upgrading to 0.18.0](#c-releases-upgrade-0180)
  - [Upgrading to 0.17.0](#c-releases-upgrade-0170)
  - [Upgrading to 0.16.0](#c-releases-upgrade-0160)
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
  - [Dependencies move with the release](#c-releases-dependencies)
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

Each upgrade section is written from the release’s entry in [CHANGELOG.md ↗](https://github.com/caramelizedev/caramel/blob/v0.20.0/CHANGELOG.md): what to run, what to edit, and what changes without an edit. Upgrade one release at a time and run the proof at the end after each.

Upgrade notes

## Upgrading to 0.20.0 {#c-releases-upgrade-0200}

Upgrade Caramel and Frappé together. Run `frappe migrate` once for a framework migration; nothing is removed; the three changes marked **Breaking** need an edit, and every user signs in again once.

- SweetTalk: `kernel Money, shared_by: [Pricing, Billing], means: "…" do … end` declares a shared kernel, a module of `value` and `aggregate` declarations that two or more named contexts or kernels share; each sharer says `shares: Money` (or `shares: [Money, Calendar]`), naming kernels declared before it. Only a sharer may name `Money::` types, run its aggregates’ commands or react to its events, a kernel may not name a context or reach `Caramel::Outbound`, and every value or aggregate of a kernel that nothing else in it uses must be named by two or more sharers; each refusal fails compilation at the line that causes it. A kernel stores like a context (`money_vouchers`), belongs to the tenant under `caramel/tenancy`, appears in the glossary with kind `kernel`, and draws a `kernel` edge in the context map ([ADR 0044 ↗](https://github.com/caramelizedev/caramel/blob/v0.20.0/docs/decisions/0044-sweettalk-shared-kernels.md)). Nothing changes for a program without one.
- `APP_ORIGIN` is normalised once: the host is lowercased and an explicit `:443` dropped, so `https://Example.com:443` works, and a request whose `Host` or `Origin` header differs from the origin only in case or by `:443` is accepted instead of answering 421 or 403. `Caramel::CSRF#origin` returns the normalised form (`https://example.com`).
- A session write that would take the `__Host-caramel_session` cookie past 4096 bytes (`session["key"] = value`, `merge!`, `update`, `put`, `put_if_absent` or `transform_values!`) raises `Caramel::Session::Overflow` at the write and leaves the session as it was, so an action fails there instead of answering 500 after the records it wrote committed. `session` is now a `Caramel::Session::Data`, a `Hash(String, String)` subclass; `Caramel::Session.fits?(data)` and `.cookie_bytes(data)` say whether and how big a hash would encode, and `Session#encode` still raises `Overflow` for a hash built some other way.
- An `update` whose changeset changes nothing no longer reports success without a query: it writes nothing (no `updated_at` bump, no version increment) but reads the row by key, tenant and loaded version, so a row deleted meanwhile adds `Record no longer exists` under `_base` and, on a versioned schema, a stale copy adds `Record changed since you loaded it` with `stale?` true. Code that relied on a no-change update of a missing row being `saved?` must handle the error.
- `SugarORM::Migrator#migrate` no longer lets a failing `pg_advisory_unlock` replace the migration’s own error: when the connection broke mid-run the statement’s exception (typically `DB::ConnectionLost`) propagates, and the unlock failure is one line on the migrator’s warnings IO; the session-level lock dies with its session anyway.
- Cold Brew’s schedule lease takes its advisory lock in Caramel’s two-key namespace (`Caramel::ColdBrew::Scheduler::LOCK_NAMESPACE`, `hashtext(name)`), so it no longer meets an application’s own `pg_advisory_lock(n)`. A schedule block that raises now counts its period as run, so the next attempt comes after its span instead of within a minute; a block that must retry sooner should enqueue a job.
- Crema’s metrics recorder upserts each window’s `caramel_metrics` rows in `(kind, key)` order, so a web process and a worker flushing the same minute no longer deadlock and drop a window.
- **Breaking:** `Caramel::Outbound` resolves the host of a direct call first and raises `Caramel::Outbound::Blocked` when any resolved address is loopback, private (RFC 1918, 100.64/10, fc00::/7), link-local, multicast or reserved, classifying v4-mapped and NAT64 addresses by their embedded IPv4; it then connects to the vetted address itself, so DNS rebinding cannot swap it. An application that calls a service on a private network sets `Caramel::Outbound.allow_private = true` at boot; calls through `Outbound.proxy`, such as Corretto’s wire proxy, are not checked. Every call reads at most 10 MiB of response (`Caramel::Outbound::TooLarge`) and finishes within 60 s in all (`IO::TimeoutError`), on top of the 5 s connect and 30 s read timeouts; `Outbound.max_response_bytes` and `Outbound.deadline` change those limits. Requests send `Accept-Encoding: identity` unless the caller sets one, and bodies are no longer decompressed.
- **Breaking:** the `__Host-caramel_session` cookie carries the second it was signed and reads as empty 14 days after its last write (`Caramel::Session::MAX_AGE`; `Caramel.build(..., session_max_age:)` or `Application.new(..., session_max_age:)` change it) or when signed more than a minute ahead of the clock. It is re-signed only when an action changes the session, so the window is absolute from the last write; it stays a browser-session cookie with no `Max-Age`. Cookies in the previous format read as empty, so every user signs in again once. `Session.new` takes the `Array(Bytes)` of `CSRF#derive_keys("session")`, and the largest session shrinks by 11 bytes.
- `APP_SECRET_PREVIOUS` (comma-separated, each at least 32 bytes) lists secrets `APP_SECRET` replaced: sessions and CSRF tokens they signed still verify, new ones are signed with the current secret, and a changed session is re-signed with it; unset it once 14 days have passed. `Caramel::CSRF.new(secret, origin, previous)` and `CSRF#derive_keys(purpose)` expose this; `derive_key` (Crema’s debug key) stays current-only. `.env.test` may not set `APP_SECRET_PREVIOUS`.
- `serve`, `work` and `seed` start when the database journal holds migrations the binary lacks, printing `WARNING: the database holds migrations this binary lacks (vN, …); starting anyway` on standard error, so an old process restarted after the new binary ran `migrate` keeps serving until cutover. A migration the binary has but the journal lacks still exits 1 with `Pending migrations. Run frappe migrate first.`; `migrate` and `lint` still refuse a journal ahead of them. `SugarORM::Migrator#pending` takes `allow_ahead : Bool = false` and `Migrator#ahead` lists the versions the binary lacks.
- The zero-lock linter gains rules `drop-table`, `truncate`, `rename-table`, `alter-column-type`, `set-not-null`, `constraint-not-valid`, `concurrent-drop-index`, `bulk-write` and `hidden-ddl`, and reads `DO $$…$$` bodies, `$tag$` quotes and `E'…'` escapes. `frappe migrate` and `frappe db diff` may now refuse hand-written migrations that passed before; each refusal names the rule, the statement and the remedy, a table created in the same migration stays exempt, and `--dev-override` is unchanged. A refusal the author means to overrule takes the line `-- caramel:allow RULE SUBJECT` above the statement (the table, `table.column`, or the index for `concurrent-drop-index`); `-- caramel:allow-drop` and `-- caramel:allow-rename` keep working. `frappe db diff` writes `-- caramel:allow alter-column-type table.column` above the checked text-to-date retype.
- Framework migration `20260927000007 index_caramel_jobs_locked_and_claim` adds `caramel_jobs_locked`, which the stale-lock release uses, and `caramel_jobs_claim`, which the claim walks instead of sorting the due backlog. A partitioned table refuses `CREATE INDEX CONCURRENTLY`, so `frappe migrate` builds them plainly, holding a SHARE lock on each job partition for the build; run it when the queue is quiet.
- A job lock whose database session is gone, or whose PID now belongs to a session started after the lock, is released by the next maintenance pass, within a minute, instead of after 15 minutes; `Maintenance.new(stale_after:)` defaults to zero. Maintenance runs every step of a pass even when one raises (reported as handled) and creates partitions first. `caramel_jobs.last_error` never holds NUL bytes or invalid UTF-8; when a failure write raises, Cold Brew stores the class alone, and if that raises too it clears the lock so the job runs again.
- Idle worker fibers poll every second (was 50 ms) and are woken at once by the enqueue’s `pg_notify('caramel_jobs', queue)` through the process’s PubSub broker; `Worker.new(idle:)` keeps the old interval, and a process without a broker polls only.
- `Caramel::SSE.relay(io, updates, event:, heartbeat:)` writes a subscription’s payloads as events and a `: ping` comment after each 15 seconds without one (`Caramel::SSE::HEARTBEAT`), so a stream whose client went away ends at the next heartbeat instead of at the next event; `Caramel::SSE.comment(io, text)` writes one comment line. Replace `loop { Caramel::SSE.write(io, event: …, data: updates.receive) }` with `Caramel::SSE.relay(io, updates, event: …)`; with `relay`, a subscription that closes ends the stream normally. The PubSub broker runs `SELECT 1` on its LISTEN connection every 30 s and reconnects when the acknowledgement does not arrive within 5 s.
- Crema redaction also removes the `user:password@` of any URL, `Cookie`/`Set-Cookie` lines and the values of PostgreSQL’s `Key (…)=(…)` detail from error messages and backtraces. The OTLP exporter normalises `db.query.text` before sending (strings and bare numbers become `?`, comments go, the text is cut to 500 bytes; `$n` binds stay). Text log lines escape control characters as `\n`, `\r`, `\e` or `\xNN` and quote the value, so client input cannot forge a line. `Caramel::Crema.trust_trace_context = false` (or `CARAMEL_TRUST_TRACE_CONTEXT=0`) ignores inbound `traceparent` and `X-Request-ID`, so a client cannot force sampling. An `http://` OTLP endpoint off the loopback interface with `OTEL_EXPORTER_OTLP_HEADERS` set logs `OTLP headers are sent in clear to HOST; use an https endpoint` at start.
- **Breaking:** a route inside the `tenant` block fails compilation unless its action, or a parent, declares `ingress authenticate: :method?`, or the action declares the new `ingress open: true`. Add one to every existing tenant action; `frappe routes` prints `[open]` for open routes. `ingress open: true` cannot combine with `authenticate:` and cannot be declared under a parent that authenticates.
- `frappe make tenancy` writes `member?` into `app/actions/application_action.cr` (true when `session["accounts"]`, the slugs this session signed up, names the tenant), guards the tenant home with `ingress authenticate: :member?`, and its sign-up action joins the session; the generated `tenant_session(slug)` signs up the slug through `/accounts`. `frappe make resource` in a multi-tenant application writes `ingress authenticate: :member?` into every tenant action, and its request spec proves 404 for another tenant’s member and 401 for a non-member. Replace `member?` with a membership table as the sessions recipe shows.
- Every git dependency in `shard.lock` is locked to the commit its tag pointed at, in Shards’ own form `version: 0.31.0+git.commit.<sha>`; `scripts/shards install` fails when a pinned shard was installed at another commit, and `scripts/check shard-pins` refuses an unpinned entry. An application generated from a release tag locks Caramel’s commit (`version: 0.20.0+git.commit.<sha>`) and copies the framework’s pinned entries. An existing application adopts the pins without `shards update`: copy the `pg`, `db`, `blueprint` and `lexbor` entries from this release’s `shard.lock` into yours, add `+git.commit.<sha>` (the release tag’s commit) to the caramel entry, then run `frappe setup`; `shards update` strips the pins, so update a dependency by writing its tag’s commit into the lock instead. `frappe lsp install` rebuilds crystalline once, with its `lsp` dependency pinned and verified.
- `frappe build` writes two files beside the artifact: `SHARD-….tar.gz.sha256`, which `sha256sum -c` or `shasum -a 256 -c` verifies, and `SHARD-….tar.gz.sbom.json`, a CycloneDX 1.5 bill of materials naming the application at its commit, the Crystal version, each shard with its version and commit, and the musl, gc, gmp, OpenSSL, pcre2 and zlib versions linked into the binary, with the image digest under `properties`. The artifact path is still the only line on standard output. `CARAMEL_BUILD_IMAGE`, set where `frappe build` runs, replaces the pinned build image, for example with one carrying a patched OpenSSL; it must name the image by digest (`…@sha256:<64 hex>`) or the build exits 1.
- `frappe corretto` reports each preparation phase with its duration (`Corretto: template checked in 0.0s`, `template migrated`, `worker databases cloned`, `workers finished`, `workers dropped`), whether each worker’s spec binary was reused or built, and ends with `Corretto: M of M workers passed in <total>`; a script that matches that line exactly needs the ` in <duration>` suffix. Worker output that stays on one line for five seconds, such as progress dots, is forwarded as far as it goes.
- Latte’s runtime directory moved from `/private/tmp/caramel-<uid>-<digest>` to `~/Library/Caches/Caramel/<digest>`, which another user cannot pre-create. Stop a daemon from an earlier release with that release’s `latte stop` before starting this one, and restart `frappe dev` sessions started under the old path. Latte refuses with `runtime_path_too_long` when a home directory would push a socket path past macOS’s 103 bytes. `scripts/crystal` keeps its OpenSSL alias under `$TMPDIR`. The trace collector answers 421 to a request whose `Host` is not `127.0.0.1`, `localhost` or `[::1]` with its port, and keeps at most 64 MiB of traces. `latte trust install` refuses, naming the file, when a key under `services/caddy/storage/pki/authorities/caramel/` is not an owned file of mode 0600.
- Latte’s DNS, HTTP and HTTPS listeners move with `CARAMEL_LATTE_DNS_PORT`, `CARAMEL_LATTE_HTTP_PORT` and `CARAMEL_LATTE_HTTPS_PORT` (1024 to 65535; defaults 15353, 18080, 18443). With `CARAMEL_HOME` a second Latte runs beside yours; the resolver and the relay serve the default ports only, and such a Latte’s HTTP listener redirects to its own HTTPS port. `frappe services start` refuses before starting anything when a listener a service needs is held, naming the owner (`DNS port 15353 is in use by coredns (pid 22064)`, `port_in_use`); a service already running keeps its port. `scripts/check latte-daemon` runs on free ports of its own, so no check needs your own Latte stopped.

## Upgrading to 0.19.0 {#c-releases-upgrade-0190}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; a SweetTalk domain that adopts the new word keeps its days in a `date` column.

- SweetTalk: `value Day, Date, means: "a calendar day"` is a real calendar day, from year 1 to 9999, over `SugarORM::Date` (`day.raw`), stored in a `date` column through `SugarORM::DateCodec`, so `has settled_on : Day`, `has returned_on : Day?` and a `part` of a value with parts each get one, and a text column that held a day, such as a former string value, is retyped by the check-first migration `frappe db diff` already derives. `where: {settled_on: from..to}` in `finds`, `counts` and `specification` takes a closed, beginless or endless range of days, `order: {settled_on: :desc}` sorts by day, and an event field and a Cold Brew job carry it as `YYYY-MM-DD`. A day is that text in JSON too, and a contract field binds it from that text with `Day must be a calendar day written YYYY-MM-DD, as in 2026-02-28` as its error. `Day.new("2026-02-30")` refuses, `Day.new(2026, 3, 1)` and `Day.of(time)` (the time’s own calendar day, with no conversion to UTC) build one, `day + 7`, `day - 7` and `day - other` move and count by days, and days compare and sort. There is no `Day.today`: a command takes the day it means as an argument. A `has` reaches a codec through a value’s `SWEETTALK_CODEC`; only `Date` names one so far (ADR 0043).

## Upgrading to 0.18.0 {#c-releases-upgrade-0180}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; a SweetTalk domain that adopts the new words gains table constraints, and one optional attribute changes its default.

- A codec may now name the `date` column type, and `SugarORM::Date` with `SugarORM::DateCodec` stores a calendar day in it: `field due_on : SugarORM::Date, codec: SugarORM::DateCodec`. A `Date` is a year, a month and a day with no time of day and no zone; `Date.parse` reads only `YYYY-MM-DD`. A `date` column read in a session whose `DateStyle` is not ISO, or holding `infinity` or a BC date, raises ArgumentError instead of guessing a day. `frappe db diff` creates and compares the column like any other. A codec that declares `ORDERABLE = true` before its schema, as `DateCodec` does, lets keyword `where` take a Range on that column (`where(due_on: first..last)`); the numeric, `jsonb` and `text` codecs still take only a value or `nil` (ADR 0042).
- A text column that the schema now declares `date` (a field with `SugarORM::DateCodec`) no longer halts `frappe db diff`: the diff derives a migration that locks the table, counts the values that are not a calendar day written `YYYY-MM-DD` and stops with that count and up to five of them if there are any, then drops the column’s default and runs `ALTER COLUMN … TYPE date USING "col"::date`. The retype rewrites the table under an exclusive lock, and the check needs PostgreSQL 16 or newer. Every other type change, including `date` back to `text`, still halts (ADR 0042).
- SweetTalk: a type followed by `?` makes a `has` attribute optional for every type it takes. `has owner : Setup::Owner?` stores a nullable `owner_id` foreign key and its getter returns the id or nil, `has settled_by : Teller?` a nullable column of its raw type, and `has leg : Money?`, a value with parts, one nullable column per part with a `CHECK` that every part is set or none is (`check_<table>_<attribute>_all_or_none_<hash>`, the hash of the value’s part names, so a part added replaces it), which loading such a row also enforces. A command points a reference with its new private writer, `self.owner = other` (the aggregate, the record or its id, or nil when optional); a projection’s `whenever` handler assigns `row.owner = other` on the row it holds, and `@owner = other`, `@owner ||= other` or a multiple assignment in a command, factory, process step, compensation or deadline, which would declare a stray instance variable, does not compile; a projection’s key has no writer. `where: {owner: nil}` in a `finds`, `counts` or `specification` asks for the rows where it is not set, and does not compile for an attribute that is not optional. A projection’s or a process’s `key` cannot be optional, and a factory takes an optional attribute declared before a required one. Use `?` for what a thing may lack: a column only some kinds have belongs in a value with parts or a state, and a rule that ties one attribute to another stays a `never` (ADR 0039).
- **Breaking:** a SweetTalk optional attribute now defaults to nil, including the existing `has note : String?`. A factory or `create` that did not set it used to fail with "factory does not set note" and now leaves it nil, so code that relied on that error no longer gets it. `order: {x: :desc}` on an optional column sorts the rows with no value first, and `:asc` last, as PostgreSQL does.
- **Upgrade, SweetTalk:** the new CHECKs and a new foreign key are added by `frappe db diff` `NOT VALID` and validated in a later step, so existing rows that break one stop `frappe migrate`. Find them first: for an optional value with parts, `SELECT id FROM <table> WHERE num_nonnulls("<attribute>_<part>", …) NOT IN (0, <parts>)`; for a foreign key added to a column that held ids, `SELECT t.id FROM <table> t LEFT JOIN <target> o ON o.id = t."<attribute>_id" WHERE t."<attribute>_id" IS NOT NULL AND o.id IS NULL`.
- SweetTalk: `value Kind, String, one_of: %w[payment receipt], means: "…"` is a string value that is one of a closed list, written once. It refuses another text, adds `Kind.all`, `Kind.includes?(text)`, `Kind.payment` and `kind.payment?`, and every column that stores it gets `check_<table>_<column>_one_of_<hash>`, which changes with the list, so `frappe db diff` replaces it when a word is added or removed; `database_check: false` keeps the list in Crystal only. The check is added `NOT VALID` like the others, so a row outside the list stops `frappe migrate`: find it with `SELECT id FROM <table> WHERE "<column>" IS NOT NULL AND "<column>" NOT IN (<words>)`. It takes neither `matches:` nor `length:`, and a word that names a method the value, every object or Crystal already has, such as `all`, `name` or `end`, does not compile. The compile error for a string value’s unknown options now names `one_of:` (ADR 0040).
- SweetTalk: `event Settled, carries: [kind, amount, owner], means: "…"` takes one field for each attribute or derived value named, of its type, and `emit Settled` reads them from the aggregate when it runs, so no command restates them. A name the aggregate lacks above the event, a name twice, or one named like the event’s metadata does not compile, and neither does an `emit` that gives a carried field, which would say what the aggregate does not hold. An optional field a job queued before it existed lacks reads as nil. `carries:` makes the event a snapshot of the aggregate, so renaming or retyping a carried attribute changes the payload of jobs already queued; a rename is safe only when the new attribute is optional, as the ADR says (ADR 0041).

## Upgrading to 0.17.0 {#c-releases-upgrade-0170}

Upgrade Caramel and Frappé together. There are no framework migrations; the toolchain changes, every model an action returns needs a `json` line, and direct callers of the ops socket send its key.

- Public files are now streamed with `Content-Length`, `ETag` and `Last-Modified`, answer 304 to a current `If-None-Match` or `If-Modified-Since`, and carry `Cache-Control: public, max-age=31536000, immutable` when the name has a three-part version (`htmx-4.0.0.min.js`) and `no-cache` otherwise. `public/.well-known/` files are served, and any other path with a hidden segment (`/.env`, `/.something`) now goes to the router instead of answering 404 in the static layer, so a route such as `/.well-known/change-password` is reachable. A file that cannot be read answers a 500 with the security headers. Ranges are not supported.
- Caramel now pins Crystal 1.22.1, which fixes io_uring event loop hangs, `OpenSSL::SSL::Options::ALL` and the `Content-Length` regressions of 1.22.0. Installing this release sets up a new toolchain directory, so its first builds start with an empty compiler cache. If you use the editor tools, run `frappe lsp install` again after installing. New applications declare `crystal: ">= 1.22.1"` in `shard.yml`, and `frappe build` compiles in `crystallang/crystal:1.22.1-alpine`. The toolchain also moves to OpenSSL 3.6.5, which fixes the advisories of 3.6.4.
- Cold Brew’s pool now holds four spare connections beside the worker fibers instead of one: one for maintenance, two for schedule blocks, and one for Crema’s recorder and console. A slow schedule block no longer makes maintenance and the other schedules fail their checkout. At most two schedule blocks run at once in a process, and a third due block waits for one to finish. A `serve` or `work` process may now hold three more connections, up to `CARAMEL_POOL_SIZE` + queues × `CARAMEL_WORKER_CONCURRENCY` + 5, so check the runtime role’s limit of 24 against the processes you run during a deploy. The most worker fibers across all queues is 28, down from 31, and `CARAMEL_WORKER_CONCURRENCY` above that limit now stops the process at start.
- Breaking for direct callers: every request to the ops socket must carry the per-start key in `<socket>.key` (mode 0600, new at each start, removed at stop). Anything that talks to the socket without `APP ops` (`curl --unix-socket`, scrapers) must send `Authorization: Bearer $(cat SOCKET.key)`; Prometheus uses `authorization: credentials_file: SOCKET.key`. A request without the key answers 401. `ops console` prints a URL containing the key, and a TCP forward without that URL gets 401.
- `frappe setup --no-migrate` installs dependencies and registers the site but leaves the development database unchanged, and prints that migrations were skipped and that `frappe migrate` applies them; `setup` without the flag still applies pending migrations.
- With `caramel/tenancy` and no tenant bound, a cache key or PubSub channel name that starts with `t<id>:` now raises ArgumentError (inside `Caramel::Tenancy.without` it is allowed), and `Caramel::Cache.clear` deletes only the bound tenant’s keys; with none bound it deletes only keys with no tenant prefix, and inside `without` every key. Wrap an app-wide clear in `without`.
- `APP db roles` (and `DatabaseRoles.role`) now validate role and database names themselves, keep a password out of the `DO $` body, and the script fails before any grant when a role that already exists has SUPERUSER, CREATEDB, CREATEROLE, BYPASSRLS or REPLICATION. Run it with `psql -v ON_ERROR_STOP=1`; the role that runs it stays a member of both roles until you revoke them.
- `frappe lint` and new applications’ `.ameba.yml` enable `Caramel/SourceTreeRead`, which reports a `File.read`, `File.open` or `Dir.glob` whose arguments contain `__DIR__`; a release artifact holds no source tree, so such a read fails only in production. Add the block to an existing application’s `.ameba.yml` to adopt it. The deploy guide now says what the artifact holds and how to embed a file with `read_file`.
- A record is written as JSON only with the columns its schema’s `json` line lists, such as `json :id, :title, :created_at, :updated_at`, where it wrote every column. Every model an action returns, or any other code writes as JSON, needs a `json` line; compilation fails without one and the error names the model. `frappe make resource` writes the line for new resources, listing the id, its fields and the timestamps, never the tenant column.
- `Caramel.content_security_policy` (in `config/application.cr`) changes the Content-Security-Policy of every response, `content_security_policy` in an action changes one response’s copy, and `csp_nonce` adds a per-response nonce to `script-src` and `style-src`. A header an action sets itself is kept. `serve` now sends `Strict-Transport-Security: max-age=31536000` when `CARAMEL_ENV` is production or unset, so a proxy that added it can stop; it is never sent in development or test.
- At the first SIGTERM or SIGINT, `serve` now stops claiming jobs and ends every PubSub subscription, so a server-sent events stream ends instead of holding the process for the whole drain. `serve` and `work` give requests and jobs in flight `CARAMEL_SHUTDOWN_TIMEOUT` seconds (1 to 3600, default 25) and log what was still running when it passes; `work` used to wait without limit, so raise the setting for jobs that run longer than 25 s. A second signal exits 1 at once. A supervisor allows `CARAMEL_SHUTDOWN_TIMEOUT` plus 5 s before it kills a process.
- `frappe dev` no longer hands the development session cookie to any client on the machine. The gateway sets it only on a single-use link, `/__caramel/dev/sign-in?nonce=…`, that `frappe dev` prints as `Toolbar and inspector sign-in (single use): URL` (also with `--no-open`) and opens, and `frappe open` mints a new one while `frappe dev` runs. The inspector pages answer 403 without the cookie, the toolbar says `Not signed in`, and `/__caramel/dev/status` shows an unsigned client only `generation` and `state`; the build-error page stays public. Open a new link after restarting `frappe dev`; Latte.app’s Open inspector item needs a signed-in browser.
- The TLS client contexts Caramel opens itself (the database connection, `Caramel::Outbound`, the OTLP exporter and Latte’s proxy probe) now clear the legacy OpenSSL 1.0 `SSL_OP_ALL` options that Crystal before 1.22.1 gives every `OpenSSL::SSL::Context` (GHSA-7jw4-6xx8-g2r9), so an application built with an older compiler is covered too: Shards only warns about the `crystal:` floor. A TLS 1.2 connection now uses the extended master secret, and a peer that closes without `close_notify` is an error. A server that cannot do secure renegotiation is refused.
- `frappe new` and `frappe setup` now run each dependency’s postinstall script themselves, after `shards install --skip-postinstall`, and keep what it writes in the toolchain’s `postinstall-cache`, keyed by the dependency’s name and version. The first install on a toolchain still builds lexbor’s parser (`cc`, `ar` and the network); the next application copies it, about 1.7 s instead of 11 s.

## Upgrading to 0.16.0 {#c-releases-upgrade-0160}

Upgrade Caramel and Frappé together. There are no framework migrations and nothing is removed; the toolchain changes, and these changes can need an edit.

- `frappe db diff` keeps an index or foreign key whose name SugarORM did not generate and prints a note, where it dropped every undeclared one. A changed index is built under a temporary `_swap` name, then the old index is dropped and the new one renamed, so a unique index is never missing. `belongs_to` takes `on_delete: :cascade`, `:restrict` or `:set_null`.
- `frappe migrate` commits each transactional migration with its own journal row instead of one shared transaction, so a failure no longer rolls back the migrations before it. A migration that hits `lock_timeout` rolls back and runs again after 1, 2 and 4 s; a fourth timeout stops `migrate` with `Migrator::LockTimedOut`, which names the migration.
- `CARAMEL_POOL_SIZE` (1 to 32) and `CARAMEL_POOL_TIMEOUT` (1 to 300 seconds) set the connection pool of every command that opens one, which was fixed at 4 connections and a 5 s checkout wait. An invalid value exits 1 with one line naming it.
- Applications can use `BigDecimal`, `BigInt` and `BigRational` in every managed build: the toolchain now bundles GMP 6.3.0, and `frappe build` links it statically. Remove any `@[Link(ldflags: …)]` on `LibGMP` and any vendored `libgmp.a` an application added for this.
- The toolchain changed, so installing this release sets up a new toolchain directory and its first builds start with an empty compiler cache. If you use the editor tools, run `frappe lsp install` again after installing.

## Upgrading to 0.15.0 {#c-releases-upgrade-0150}

Upgrade Caramel and Frappé together. Run `frappe migrate` once for a framework migration; these changes can need an edit.

- Every database connection sets `statement_timeout` and `lock_timeout` when it opens, and the client’s read timeout follows the statement timeout, 5 seconds behind it. `serve`, `work`, `seed`, `lint` and `drift` default to 30 s and 5 s; `migrate` defaults to no statement timeout and 5 s. A statement that ran longer than 30 s now fails with `canceling statement due to statement timeout`. Raise `CARAMEL_STATEMENT_TIMEOUT` or `CARAMEL_LOCK_TIMEOUT` for a process that needs longer, and `CARAMEL_MIGRATION_STATEMENT_TIMEOUT` or `CARAMEL_MIGRATION_LOCK_TIMEOUT` for `migrate`: whole seconds, 0 to 86400, 0 for none. [The Crema reference lists the variables →](https://caramelize.dev/docs/0.20.0/crema/index.md)
- A job whose process dies or loses its connection is failed on its third release instead of being redelivered forever: maintenance records `Caramel::ColdBrew::AbandonedJob`, calls the `on_failed` hooks, and `jobs retry` runs it again. Released runs no longer count against `retry_on` attempts.
- The framework migration `20260927000006` adds `caramel_jobs.releases` and takes a lock on every `caramel_jobs` partition. Run `frappe migrate` while no job is running, or `migrate`’s 5 s lock timeout may refuse it; `CARAMEL_MIGRATION_LOCK_TIMEOUT` raises it.

## Upgrading to 0.14.0 {#c-releases-upgrade-0140}

Upgrade Caramel and Frappé together. There are no framework migrations; an application with a SweetTalk domain adds one of its own, and these changes can need an edit.

- With `caramel/sweet_talk`, a `SweetTalk::Refusal` that an action’s `handle` does not rescue answers 422 with its message under `_base`, shaped like a failed contract: `{"errors": {"_base": [message]}}` for JSON clients, the contract failure page for browsers and htmx, and text starting `ERR INVALID:422` for other clients. A `SweetTalk::Missing` answers 404. Neither is reported to Crema as an error. An action that rescues them itself is unchanged, and `SweetTalk::Boundary` still answers 500. Asking an aggregate for its id before `create`, or an event for its subject before it is emitted, raises `NilAssertionError` instead of `SweetTalk::Missing`.
- A contract field may take a SweetTalk value or an aggregate’s id: `field quantity : Ordering::Quantity` binds as an `Int32`, and the value’s refusal is the field’s error. `CARAMEL_FIELD_<NAME>` constants gain a sixth element, the declared type, so a macro of your own that destructures exactly five must take six.
- A lifecycle’s `state` column has a `CHECK` constraint named `check_<table>_state_<8 hex digits>`, and a state of two or more words is stored as `moves` spells it. 0.13.0 stored `awaiting_payment` as `awaitingpayment`: first add a migration that respells such rows, such as `UPDATE ordering_payments SET state = 'awaiting_payment' WHERE state = 'awaitingpayment'`, and migrate, then run `frappe db diff`, which adds each constraint as `NOT VALID` and validates it in the `_concurrently` migration. `frappe migrate` stops, naming the constraint, while a row holds any other text; the constraint stays `NOT VALID` until you fix those rows and migrate again. A lifecycle whose constraint name would pass PostgreSQL’s 63 bytes no longer compiles; give the context or the aggregate a shorter name, since `renamed_from:` keeps the old table and its long name.
- A `finds` that names an unknown attribute or state, or a list of entities, fails to compile even when nothing calls it. Code outside an aggregate can no longer call `__sweettalk_rows`; give the aggregate a `finds` with a block instead.
- Calling another context’s service, as in `Catalogue.price_of(tea)`, counts as naming `Catalogue::`: outside `border Catalogue` it compiles only where the context follows Catalogue. Move the call into the border, or declare `follows: Catalogue`. In a border the call draws a dependency edge, so two contexts whose borders call each other no longer compile: let one of them react to the other’s events instead. A context names `Caramel::Outbound` or `HTTP::Client` only inside a border with an outside system, `border Cards, outside: "…" do … end`.
- Additive, nothing to edit: `specification` names a rule once, `finds` and `counts` sort, limit and count, a context names its `subdomain:` and what it `publishes`. [The SweetTalk guide lists them →](https://caramelize.dev/docs/0.20.0/sweettalk/index.md)
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
- Applications can run in production on Linux: `frappe build` writes a static linux/amd64 artifact, `serve` reads public files from `CARAMEL_ROOT` and runs without workers with `--no-workers`, `APP jobs unknown` lists queued jobs a binary cannot run and `APP db roles` prints the role script. Nothing to edit. [The Production guide puts them in order →](https://caramelize.dev/docs/0.20.0/deployment/index.md)

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

[What Crema adds →](https://caramelize.dev/docs/0.20.0/observability/index.md)

## Earlier releases {#c-releases-earlier}

The notes start at 0.8.0, the release that first put its upgrade steps on this page. Each release’s guides stay published at `/docs/VERSION/` from 0.4.0 on, and CHANGELOG.md holds every release’s notes. The ones before 0.8.0 that still need an edit: 0.7.0 changes `html lang: "en"` in `app/views/layouts/application.cr` to `html lang: Caramel.language` and replaces `Caramel::Application::EXPIRED_FORM` with `Caramel::Wording.expired_form`; 0.6.0 adds Lexbor 3.6.4 under `development_dependencies`; 0.5.0 binds JSON bodies through the contract and gives specs a committed `.env.test`; 0.4.2 pins Crystal 1.21.1.

Supported today

## Runtime and local tools {#c-releases-tools}

Caramel is a source-built Crystal framework with a managed toolchain; the versions it pins and the machine it develops on are stated once, in [Your first application](https://caramelize.dev/docs/0.20.0/getting-started/index.md). Frappé creates projects, generates resources and supervises builds; Latte supplies managed services and named HTTPS. An application’s `shard.lock` selects its framework release, and Frappé dispatches to the matching installation; `frappe installations install VERSION` installs another release beside this one.

[Caramel 0.20.0 source release ↗](https://github.com/caramelizedev/caramel/releases/tag/v0.20.0)

## Dependencies move with the release {#c-releases-dependencies}

Four dependencies are held to one version. An upgrade of any of them waits for a Caramel release. The framework’s `shard.lock`, and the lock of every generated application, locks each git dependency to the commit its tag pointed at (`version: 0.31.0+git.commit.<sha>`), so a moved tag changes nothing; `scripts/check shard-pins` refuses an unpinned entry.

| Dependency | Held to | What an upgrade waits for |
| --- | --- | --- |
| Blueprint | `1.1.0`, exactly | Caramel reopens its attribute renderer (ADR 0018 decision 4), so a Blueprint upgrade waits for a Caramel release that re-verifies the patch |
| Crystal | `1.22.1` and newer in `shard.yml`, tested on `1.22.1` | A newer compiler is untested until a release names it; the pinned toolchain and the build image are `1.22.1`, stated in [Your first application](https://caramelize.dev/docs/0.20.0/getting-started/index.md) |
| htmx | `4.0.0`, copied into `app/assets/vendor/` | Your application owns that copy, but fragment negotiation is tested only against 4.x (ADR 0004) |
| Lexbor | `3.6.4`, development only | Corretto binds its native layout, so a Lexbor upgrade waits for a release; production installs omit it |

## Requests and responses {#c-releases-requests}

Typed action contracts bind route and query values, URL-encoded forms, multipart uploads, and JSON objects. The default policy checks CSRF for writes and limits ordinary request input to 2 MiB; multipart uploads have a separate 64 MiB budget. Use per-action `ingress` for a custom limit, authenticated APIs, or exact raw webhook bytes.

Actions return HTML or JSON according to the request. `render_errors` handles errors found after contract binding. Blueprint views write typed HTML with escaped text and attributes; htmx partial responses update selected page regions.

## Data and resource generation {#c-releases-data}

SugarORM provides typed schemas, codecs for any field type, changesets, queries, explicit preloads, row locks, upserts, version columns and CHECK constraints. Derive a migration with `frappe db diff`, review it, and apply it with `frappe migrate`; `frappe seed` runs `db/seeds.cr`. `frappe make resource` generates application-owned models, changesets, actions, views, routes, migrations, and request specs.

Use `:server` for fields populated by the action, `:unique` for unique indexes and constraint checks, and `:url` for URL validation and inputs. `--only=create,show` generates a smaller action set; create and show are required, and edit needs new and update.

[Read the SugarORM reference →](https://caramelize.dev/docs/0.20.0/sugarorm/index.md)

## Background work {#c-releases-work}

Cold Brew stores jobs in PostgreSQL and supports transactional enqueueing, retry policies, durable status, retry and failure hooks, renamed jobs, recurring schedules, PubSub, and cache. A job whose process died on three of its runs fails as `Caramel::ColdBrew::AbandonedJob` and can be retried. The application binary runs queues through `serve` or a worker-only `work` process with queue and concurrency options. External calls can repeat, so use a stable identifier for deduplication.

[Read the Cold Brew reference →](https://caramelize.dev/docs/0.20.0/cold-brew/index.md)

## Development and testing {#c-releases-checks}

Corretto drives in-process application requests against isolated test databases. Its client sends forms, multipart uploads, JSON, or exact raw bodies. Blueprint-shaped `have_html` expectations inspect decoded rendered HTML; `render_partial` can check an envelope’s target, swap, and content together.

Generated applications pin Lexbor 3.6.4 under development dependencies. Development installs need cc, ar, and network access for the verified native parser source. Production installs omit the parser. Put application-owned test settings in committed `.env.test`; development `.env` does not reach specs.

Every page of these guides has a Markdown edition at its address followed by `index.md`, listed in `https://caramelize.dev/docs/0.20.0/llms.txt`, and `frappe agent-manifest` prints that address on its `GUIDES:` line.

## Internationalization {#c-releases-i18n}

Caramel has opt-in, typed translations. Run `frappe make locale CODE` to add Crystal catalogs and enable translated resource generation. Views and actions use `t` for messages and `l` for number and time formatting. Language selection supports a switch, optional URL prefixes, cookies, and browser preferences.

Contract and changeset errors, JSON error messages, and framework pages use the request’s locale. Missing translations fall back, and `frappe translations` reports what remains. Background jobs carry their language explicitly.

[Translate your application →](https://caramelize.dev/docs/0.20.0/internationalization/index.md)

## Multi-tenancy {#c-releases-tenancy}

An application can be multi-tenant. `frappe make tenancy MODEL` adds the tenant schema, sign-up and home pages, and a `tenant` block in the routes; resources generated afterwards belong to the tenant, and `--central` makes one every tenant shares.

[Add tenants →](https://caramelize.dev/docs/0.20.0/multi-tenancy/index.md)

## Domain-Driven Design {#c-releases-sweettalk}

An application can model its domain in SweetTalk, an opt-in language whose contexts, values, aggregates, events, policies, projections and processes expand into SugarORM and Cold Brew. `frappe make domain NAME CONTEXT --means=TEXT` starts one in `app/domain/` and writes a skill that gives agents its rules. Since 0.14.0 a refusal answers 422 from an action, values and ids bind as contract fields, and a lifecycle’s states are held in a PostgreSQL check. Since 0.18.0 an attribute may be optional, a string value may be one of a closed list, and an event may carry the aggregate’s attributes. Since 0.19.0 a value may be a calendar day. The guide maps each Domain-Driven Design pattern to its word and states its experimental status; the Box Office path builds one domain end to end.

[Speak the domain’s language →](https://caramelize.dev/docs/0.20.0/sweettalk/index.md) [Build a box office →](https://caramelize.dev/docs/0.20.0/box-office/index.md)

## Observability {#c-releases-observability}

Every routed request, job and schedule run gets a request id, a trace and one canonical log line. In development, `frappe dev` adds an inspector, a toolbar, richer error pages and the `frappe traces`, `trace` and `errors` commands. In production, an owner-only ops socket serves status, Prometheus text, recent errors and a console; the recorder and the OTLP exporter are opt-in. Latte adds statement statistics, menu-bar error counts and notifications, per-site access logs and a local trace collector on `127.0.0.1:4318`.

[Read the observability guide →](https://caramelize.dev/docs/0.20.0/observability/index.md)

## Production {#c-releases-production}

An application runs in production on Linux: `frappe build` writes a static linux/amd64 artifact, `serve --no-workers` and `work` are the process roles, `GET /health` answers readiness, SIGTERM drains for up to `CARAMEL_SHUTDOWN_TIMEOUT` seconds (default 25), `APP db roles` prints the role script and `APP jobs unknown` checks the queue before cutover. Every connection carries the statement and lock timeouts of 0.15.0.

[Read the Production guide →](https://caramelize.dev/docs/0.20.0/deployment/index.md)

Limits

## Current limits {#c-releases-limits}

- Caramel ships no command that provisions servers or deploys; `frappe build` ends at the artifact.
- No generator for authentication: the sessions recipe shows the tables and actions to write by hand.
- Multipart files are parsed and bounded, but no recipe yet stores a file and removes it; `storage/` is generated empty.
- Frappé has no extension point for commands of its own; an application adds commands to its binary with `Caramel::Crema.command`.
- Installing a release still starts from a Git checkout of the framework: `frappe installations install VERSION` exists once one release is registered, and there is no installer for a machine without one.
- Recipes labelled Draft are written against 0.20.0 and not run end to end; the cookbook marks each.
- SweetTalk is experimental until an application has run it in production.
- Prometheus text is served only on the owner-only ops Unix socket (`/v1/metrics`), so a scraper needs a bridge on the host. [Read the socket rules →](https://caramelize.dev/docs/0.20.0/crema/index.md)
- One `APP_SECRET` signs sessions, CSRF tokens and debug tokens; `APP_SECRET_PREVIOUS` keeps sessions and CSRF tokens readable while it rotates, debug tokens end at once. [Read what a change ends →](https://caramelize.dev/docs/0.20.0/security/index.md)
- Errors on the ops socket live in memory only. [Read what a restart clears →](https://caramelize.dev/docs/0.20.0/observability/index.md)
- No API reference is published; API detail is in doc comments at the code.

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

[Take the application to production →](https://caramelize.dev/docs/0.20.0/deployment/index.md)

Caramel 0.20.0 · https://caramelize.dev/docs/0.20.0/releases/
