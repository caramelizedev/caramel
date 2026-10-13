Reference / Crema

# See what your application did.

Crema is Caramel’s observability: request ids, one log line for every request, job and schedule run, error reports, an owner-only ops socket, an opt-in recorder and exporter, and the development tools. This page lists every name, field, variable and limit.

## What runs where {#c-cremaref-where}

Crema is part of every application. What it does depends on how the process runs and which parts you opt into. The Observability guide walks through using it.

[Read the Observability guide →](https://caramelize.dev/docs/0.14.0/observability/index.md)

- `Always on`: A request id and trace for every routed request, job and schedule run; the canonical log line; error reports; the in-memory error and trace rings; the metrics behind `ops metrics`. A `serve` process also opens the ops socket.
- `Opt in`: `require "caramel/crema/recorder"` keeps latency history in the database; new applications already have it. `require "caramel/crema/otlp"` exports traces to a tracing backend.
- `Development only`: Code compiled with `-D caramel_development`, which `frappe dev`, `frappe check` and one-shot development builds pass, and run with `CARAMEL_ENV=development`: the error page, `dump`, `Server-Timing`, query binds and source lines, and the event sink behind the inspector.

## Settings and hooks {#c-cremaref-api}

Set these in `config/application.cr`, before the application starts.

- `Caramel::Crema.slow_request`: `Time::Span`, default 1 second. A request at least this slow is kept in the trace ring as slow and flagged in the toolbar.
- `Caramel::Crema.slow_job`: Default 5 seconds. Applies to jobs and schedule runs.
- `Caramel::Crema.slow_query`: Default 100 milliseconds. Each statement at least this slow counts in the log line’s `slow_queries`.
- `Caramel::Crema.on_error { |report| … }`: Called for every error report, handled or not, with the redacted message and backtrace.
- `Caramel::Crema.report(error, handled: true, source: nil)`: Reports an error you rescued. It never raises. A handled report writes a WARN line and leaves the trace’s outcome `ok`; `handled: false` marks the trace failed.
- `Caramel::Crema.measure(kind, name, detail = nil) { … }`: Times a block as a span of the current trace. Kinds: `sql`, `http`, `view`, `enqueue`, `log`, `dump` and `domain`.
- `Caramel::Crema.command(name, syntax) { |arguments| … }`: Adds a command to the application binary and returns its exit code. The first word of the syntax is the name; registering a name again replaces the earlier command. The binary’s usage text lists the syntax.
- `Caramel::Crema.console_page(segment) { |request| … }`: Adds a page at `/segment` to the ops console. The block returns HTML.
- `Caramel::Crema.subscribe(sink)`: Adds a sink that receives finished traces and error reports. Remove it with `unsubscribe`.
- `Caramel.dump(value)`: Development only. See below.

## Environment variables {#c-cremaref-env}

- `CARAMEL_ENV`: `development` adds request paths and error messages to log lines. In a development build it also turns on the error page, `dump`, `Server-Timing`, query binds and the literals behind **Copy with values**. `test` and `development` default the log format to text. Unset counts as `production`.
- `CARAMEL_LOG_FORMAT`: `json` or `text`. Any other value falls back to text in development and test, JSON elsewhere.
- `LOG_LEVEL`: Default `Info`. Applies to every log source, not only `crema`.
- `CARAMEL_OPS_SOCKET`: A path for the ops socket, or `off`. Unset, a `serve` process uses its `CARAMEL_SOCKET` path with `.sock` replaced by `.ops.sock`. A `work` process opens a socket only when this names a path. The `ops` client reads the same variables.
- `CARAMEL_EDITOR`: An editor preset or a link template. See the development section.
- `CARAMEL_PROJECT_ROOT`: The project root, default the current directory. Error locations are shown relative to it, and its `app`, `config`, `src` and `db` folders count as your code.
- `APP_SECRET`: The application secret. Debug tokens are signed with a key derived from it, so rotating it ends every token.
- `CARAMEL_DEV_EVENTS`: Set by `frappe dev` for development builds: the socket the application sends its events to. Do not set it yourself.
- `OTEL_*`: Seven variables read by the exporter; see below.

## Ids and propagation {#c-cremaref-ids}

- `X-Request-ID`: An inbound value of 8 to 128 characters from `A-Z a-z 0-9 . _ : -` is kept; any other value is replaced by a UUID. Every traced response carries the id. Static files and the 400 and 421 refusals are not traced and carry none.
- `traceparent`: Version `00` with lowercase hex: a 32-digit trace id, a 16-digit parent id and flags. All-zero ids are ignored. A valid header continues the caller’s trace and supplies the log line’s `trace_id` and `parent_id`; the first flag bit says whether the caller sampled it.
- `Jobs`: `enqueue` stores the trace context in `caramel_jobs.context`: the traceparent, the request id and the debug flag, never a message. The job continues that trace. A schedule run starts a new trace. A missing or malformed context also starts a new one.
- `Caramel::Outbound`: Each call is an `http` span named `METHOD host`, and sends a `traceparent` unless you set one.
- `X-Caramel-Trace`: Sent only for a debug trace: the trace id.

## The log line {#c-cremaref-log}

The `crema` log source writes one INFO line for each finished trace, named `request`, `job` or `schedule`. A field with no value is left out. Every log entry written inside a trace also carries `trace_id` and `request_id`.

- `name`: Always. `GET /books/:id`, the job class or the schedule name. An unrouted request is `GET (none)`; a method outside GET, HEAD, POST, PUT, PATCH, DELETE and OPTIONS is `OTHER`.
- `request_id, trace_id, parent_id`: The ids above. `parent_id` only with a valid inbound or stored traceparent.
- `duration_ms, outcome`: Always. `outcome` is `error` after an unhandled error or a 500, or when a job’s `perform` raised, even if it will retry.
- `method, route, action, status, bytes, streamed`: Requests. `route` and `action` only when a route matched; `bytes` is left out for a streamed response.
- `path`: Requests, only when `CARAMEL_ENV=development`.
- `job_id, queue, attempt, queue_lag_ms`: Jobs. The lag is the time past `run_at`, never negative.
- `db_count, db_ms, db_wait_ms`: Statements, their time, and the wait for a pooled connection.
- `view_ms, outbound_count, outbound_ms`: The outermost view’s time and the `Caramel::Outbound` calls.
- `cache_hits, cache_misses, enqueued`: `Caramel::Cache` reads and jobs enqueued.
- `slow_queries, repeated_queries`: Statements past `slow_query`, and distinct statements that ran five or more times. Repeats are counted only when the trace records spans: the ops socket, the recorder or the exporter is on, or the build is for development.
- `debug`: `true` for a debug trace.
- `error_class, fingerprint`: Only when the trace ended in an unhandled error.

There is no `slow` field: a slow request or job shows in the trace ring, the toolbar and the inspector, and a slow statement in `slow_queries`.

- `error line`: One `error` entry for each report: WARN when handled, ERROR when not. Fields: `error_class`, `fingerprint`, `location` (relative `file:line`), `source` (the trace name, or `stream` or `cold_brew.worker`, `.maintenance`, `.scheduler`, `.hooks NAME`), `handled`, `request_id` and `trace_id`. The `message` is added only when `CARAMEL_ENV=development`.
- `JSON`: One object per line: `ts` (UTC, milliseconds), lowercase `level`, `source`, `msg`, then the fields. A field named like one of those four is written as `data_NAME`, so an error’s `source` becomes `data_source`.
- `text`: `HH:MM:SS.mmm LEVEL` and a one-line summary, such as `request GET /books/:id 200 12ms db=3/4ms view=2ms`. Values with spaces are quoted.

## Error reports {#c-cremaref-errors}

- `Fields`: `error_class`, `message`, `backtrace` (at most 50 frames of 2,048 bytes), `fingerprint`, `location`, `handled`, `source`, `request_id`, `trace_id`, `occurred_at` and the classes of up to five causes. A message is cut to 8,192 bytes.
- `Fingerprint`: The first 12 hex digits of a SHA-256 over the error class, the path of the first frame in your own code and its method name. With no such frame, the first parseable frame; with none, the class alone. Lines, columns and messages are never hashed.
- `Redaction`: Applied to every message and backtrace frame: values of environment variables whose names contain `SECRET`, `PASSWORD`, `TOKEN`, `API_KEY` or `DATABASE_URL` become `[redacted]`; PostgreSQL URLs become `[database URL redacted]`; `name=value`, `name: value` and JSON pairs whose name holds password, secret, token, api key, access key, private key, credential or authorization, and bare `Bearer` tokens, become `[credential redacted]`. If redaction fails the report keeps its class and the message `[unavailable]`.
- `Where it lives`: A report’s message and backtrace exist in memory: the ring behind `ops errors`, and development surfaces. They are never in logs, tail events, metric labels, exports or database tables.

## SQL tags {#c-cremaref-sql}

Every statement run inside a trace starts with a comment: `/*action='App%3A%3ABooks%3A%3AShow'*/` for a request, `/*job='…'*/` for a job and `/*schedule='…'*/` for a schedule. The value is the action or job class or the schedule name, percent-encoded. Pools name themselves in `application_name`: `caramel-web` for `serve`, `caramel-cold-brew` for workers and `caramel-listen` for PubSub.

## The ops socket {#c-cremaref-ops}

An HTTP/1.1 server on a Unix socket, for the application’s owner. The directory must be private: a real directory you own with no group or other permissions; otherwise the socket stays off, the application keeps serving and the log says why. The file is mode 0600. A live socket is never replaced; a dead one is. Each connection has a 10-second read and write timeout.

A request whose `Host` is not `ops`, `localhost`, `127.0.0.1` or `[::1]` gets 421. A write with an `Origin` header gets 403. A wrong method gets 404. Answers are JSON with a `version`, and carry `Cache-Control: no-store`.

- `GET /v1/status`: App, role, uptime, environment, in-flight work, request counts and p95, memory, database pools, workers, scheduler, sinks and dropped events.
- `GET /v1/requests, /v1/fibers`: In-flight requests and jobs; fibers grouped by name.
- `GET /v1/metrics`: Prometheus text.
- `GET /v1/tail`: Server-sent events of finished traces and errors. Query: `errors=1`, `slow=MS`, `logs=1`. At most 8 at once; more get 429. A debug trace always passes the filters. With `logs=1` the events include log lines exactly as written to stdout.
- `GET /v1/errors, /v1/errors/FINGERPRINT`: Errors since the process started, grouped, newest first. The second route is the only one that returns a message and backtrace.
- `GET /v1/traces?limit=N&reason=error|slow|debug`: The trace ring, 50 by default, at most 200. A trace is kept when it failed, was slow or carried a debug token.
- `GET /v1/traces/REF`: One trace with its spans. REF is a prefix of at least 6 characters of a trace id or request id.
- `POST /v1/debug-tokens`: JSON `{"minutes": N}`, 1 to 120, default 15, in a body of at most 1 KiB. Without an application secret, which a `work` process lacks, it answers 404.

The read-only console is the same data as HTML at `/`, `/requests`, `/tail`, `/jobs`, `/database`, `/errors`, `/traces` and `/insights`. It can neither retry a job nor issue a token, and its content security policy allows only its own scripts and styles.

## Commands in the application binary {#c-cremaref-commands}

The commands page lists each one; these are the details. Run `ops` where the process runs; `--socket=PATH` works on every subcommand. Exit 0 is success, 1 a failure or nothing found, 2 a usage error. `ops errors` shows UTC times; `ops traces` and `ops tail` show local times.

[See every command →](https://caramelize.dev/docs/0.14.0/commands/index.md)

- `APP ops status [--json]`: A summary of the process. `--json` prints the status document.
- `APP ops requests|fibers [--json]`: In-flight work; fibers by name.
- `APP ops metrics`: Prometheus text, as served.
- `APP ops tail [--errors] [--logs] [--slow=MS] [--json]`: Streams until you stop it. `--slow` takes a value here, and `MS` must be an integer; without one it is a usage error.
- `APP ops errors [--json]`: Fingerprint, count, last seen, class, location and source.
- `APP ops error FINGERPRINT`: One error with its redacted message and backtrace. A miss says that restarts clear the rings.
- `APP ops traces [--errors|--slow|--debug] [--limit=N] [--json]`: One reason flag; errors win over slow, slow over debug. The reason flags take no value: `--slow=500` is a usage error.
- `APP ops trace REF [--md]`: One trace as text or Markdown.
- `APP ops debug-token [--minutes=N]`: Prints the token, its expiry, a `curl` line with the header and a browser line that sets the cookie.
- `APP ops console`: Prints `ssh -N -L 8765:SOCKET HOST` and `http://localhost:8765/`. It does not connect.
- `APP jobs [stats]`: Each queue’s running, retrying, queued, scheduled and failed jobs, the finished in the last hour and the age of the oldest due job.
- `APP jobs failed [--limit=N]`: Failures grouped by job class and error class, newest first; default 20.
- `APP jobs show ID`: Every column of one job, including `last_error` and `context`. It prints to your terminal only.
- `APP jobs retry ID|--class=NAME`: Writes to the database: clears the failure and runs the job once more. It keeps `attempts`.
- `APP jobs unknown`: The queued job classes this binary does not compile, one per line, for a deploy to check before the binary takes over; exit 1 when any exist. With no `caramel_jobs` table yet, it prints nothing and exits 0.
- `APP db diagnose`: Sections `connections`, `long_running` (over 1 second), `blocking`, `cache_hit`, `seq_scans`, `unused_indexes`, `vacuum`, `table_sizes` and `outliers` (the slowest statements of your role, from `pg_stat_statements`). An unreadable section says so and the rest continue. Exit 0 if any section was readable.
- `APP db roles DATABASE MIGRATION_ROLE RUNTIME_ROLE`: Prints a psql script that creates the two login roles, the database the migration role owns and the grants Latte gives a site: the runtime role reads and writes rows through default privileges. It sets no passwords, grants both roles to the role that runs it, and needs no database. Names match `[a-z_][a-z0-9_]*`, up to 63 characters; another name exits 2.
- `APP insights [--since=DURATION] [--kind=KIND]`: The recorder’s tables. Defaults `1h` and `request`.

`jobs`, `db diagnose` and `insights` need `DATABASE_URL` and no running application. `jobs` refuses `CARAMEL_ENV=test`. `insights` without the recorder prints how to add it and exits 1.

## Prometheus metrics {#c-cremaref-metrics}

Values count from the process start and are not stored. Request routes are route templates; an unmatched route is `(none)`. More than 1,000 distinct request series fold into `(other)`. Durations are histograms in seconds with bounds from 0.005 to 10 and `+Inf`.

- `caramel_requests_total`: counter: `method`, `route`, `status`.
- `caramel_request_duration_seconds`: histogram: `method`, `route`.
- `caramel_jobs_total`: counter: `job`, `outcome`.
- `caramel_job_duration_seconds`: histogram: `job`.
- `caramel_job_queue_lag_seconds`: histogram: `queue`.
- `caramel_schedules_total`: counter: `schedule`, `outcome`.
- `caramel_errors_total`: counter: `error_class`.
- `caramel_inflight`: gauge: `kind` is request, job or schedule.
- `caramel_gc_heap_bytes, caramel_gc_free_bytes`: gauges for the Crystal heap.
- `caramel_gc_allocated_bytes_total`: counter of bytes allocated.
- `caramel_fibers`: gauge: fibers alive.
- `caramel_db_pool_connections`: gauge: `pool`, `state` is open, idle or in_flight.
- `caramel_db_pool_max`: gauge: `pool`, the pool’s limit.
- `caramel_crema_dropped_total`: counter: `sink`, events a sink lost.
- `caramel_build_info`: gauge, always 1: `app`, `caramel`.
- `caramel_process_start_time_seconds`: gauge: when the process started.

## Debug tokens {#c-cremaref-debug}

A token is `EXPIRY.SIGNATURE`: the expiry as Unix seconds and an HMAC-SHA-256 of it, keyed from the application secret. It is valid until its expiry and never longer than two hours, whatever it claims. Send it as `X-Caramel-Debug` or in the `__Host-caramel_debug` cookie; the header wins, and an invalid header is not replaced by the cookie. The request is traced in full, answered with `X-Caramel-Trace`, kept in the trace ring with the reason `debug`, always exported when the exporter is on, and passed to the jobs it enqueues. The signature covers only the expiry, so anyone holding the token can use it until then.

## The recorder {#c-cremaref-recorder}

`require "caramel/crema/recorder"` aggregates each finished trace in memory and writes to `caramel_metrics`, which comes with Cold Brew’s framework tables, so run `frappe migrate` after upgrading. It stores route templates, job classes, schedule names, parameterized SQL and outbound hosts, never a path, a bind value, a message or a trace.

- `caramel_metrics`: `bucket` (the start of the minute), `kind`, `key`, `count`, `errors`, `total_ms`, `max_ms` and `histogram`, a 12-bucket latency count. The primary key is (`bucket`, `kind`, `key`). Rows merge by adding counts and keeping the larger maximum.
- `kind`: `request`, `job`, `schedule`, `sql` or `outbound`.
- `SQL keys`: Quoted literals and bare numbers become `?`, `IN (…)` lists become `IN (?)`, whitespace collapses, and the key is cut to 500 bytes.
- `Caramel::Crema::Recorder.flush_interval`: Default 15 seconds. Each flush upserts into the current minute.
- `Caramel::Crema::Recorder.retention`: Default 7 days. Pruned hourly.
- `Limits`: 500 keys of each kind per flush, the rest in `(other)`. A failed flush loses its batch, writes one warning and counts toward `caramel_crema_dropped_total`.

## The OTLP exporter {#c-cremaref-otlp}

`require "caramel/crema/otlp"` exports each sampled request, job and schedule run as OTLP over HTTP with JSON bodies, with a child span for every query and outbound call. Nothing is sent unless an endpoint is set. Protobuf is not supported. The exporter reads these variables and no other `OTEL_*`.

- `OTEL_EXPORTER_OTLP_ENDPOINT`: The base URL; `/v1/traces` is appended.
- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`: Used as given, and wins over the base.
- `OTEL_EXPORTER_OTLP_PROTOCOL`: Unset or `http/json`. Anything else logs a warning and leaves export off.
- `OTEL_EXPORTER_OTLP_HEADERS`: Comma-separated `name=value` pairs, percent-decoded.
- `OTEL_SERVICE_NAME`: Default: the application’s title.
- `OTEL_TRACES_SAMPLER`: `always_on`, `always_off`, `traceidratio` (the default), `parentbased_always_on`, `parentbased_always_off` or `parentbased_traceidratio`. An unknown name warns and uses `traceidratio`. A parent-based sampler follows the caller’s flag when there is one.
- `OTEL_TRACES_SAMPLER_ARG`: The ratio, 0 to 1; default 1.

- `Spans`: A request is a server span, a job a consumer span and a schedule an internal span; queries and outbound calls are client spans. `log` and `dump` spans are never exported. Attributes are route templates, `db.query.text` with parameterized SQL, the HTTP method and status, the job’s queue, id and attempt, and `caramel.request_id`. A failed trace adds the exception’s class only.
- `Sampling`: Decided once per trace. A failed trace that sampling skipped is exported as its root span. A debug trace is always sampled.
- `Delivery`: Up to 2,048 traces wait in memory and go out every 5 seconds or at 512 spans, with a 5-second connect and 10-second read timeout. A failed batch is dropped, counted, and logged at most once a minute.

## Development tools {#c-cremaref-dev}

Everything here needs a development build and `CARAMEL_ENV=development`; a check confirms a production binary holds none of it.

- `Error page`: An unhandled error answers 500 with the class, the redacted message, up to 80 frames with Open in editor links, four lines of source either side of your first frame (files under `app`, `config`, `src` or `db` up to 1 MiB), the request, the queries before the error and the causes. A client that asks for JSON first gets an `error` object with the class, message, location, request and trace ids and backtrace instead.
- `dump(value)`: Prints `dump file:line: value` to standard error and returns the value; inside a trace it adds a `dump` span of up to 8,192 bytes. In actions, views and jobs, and as `Caramel.dump`. In other builds it returns the value untouched.
- `Server-Timing`: `db;dur=…;desc="N queries", view;dur=…, total;dur=…`, except on streamed responses.
- `Toolbar`: `frappe dev` adds it to full HTML responses that carry an `X-Request-ID`, not to htmx partials, the build-error page or the inspector. It shows the route, status, time and query count, flags for errors, slow requests and repeated queries, and the last ten requests. Each part links to `#timeline`, `#queries` or `#error` on the request’s page (the Timeline and Queries sections are on the page even when empty and say so; the Error section is there for a failed request). The minimise button shrinks it to a dot, and the dot restores it. `` ` `` opens and closes the list, `j` and `k` move in it, `Esc` closes it; shortcuts are ignored in fields and with a modifier key. **Copy for an agent** fetches `/__caramel/dev/trace.md?id=ID` (a hexadecimal id of 6 to 32 characters, development session only). **Theme** cycles auto, light and dark. It polls every 400 ms and reloads when the build changes.
- `Inspector`: `/__caramel/dev/inspector` lists up to 500 traces, filtered by `?only=errors`, `slow` or `jobs`. Beside it: `/inspector/traces/ID` (a prefix of at least 6 characters), `/inspector/errors` and `/inspector/builds`. Each query on a trace page has **Copy SQL** and **Copy with values**; the values come from literals built when the query ran (numbers and booleans bare, text, times and bytes quoted, `nil` as `NULL`, arrays as `ARRAY[…]`) and never leave development. Placeholders without a value stay as `$n`. The page follows the system’s light or dark appearance; the Theme button sets it for the toolbar and the inspector together (`localStorage` key `caramel.dev.theme`). Its endpoints answer GET only and check the host.
- `CARAMEL_EDITOR`: A preset or a template with `{path}`, `{line}` and `{column}`. Presets: `zed` (the default), `vscode`, `cursor`, `sublime`, `textmate` and `idea`. `frappe dev` also reads it from the project’s `.env`. An unrecognised value falls back to `zed`.
- `Caramel/Dump`: `frappe lint` reports any call to `dump` without a receiver or on `Caramel`, including your own method of that name. The rule is on in new applications’ `.ameba.yml`.

## Frappé commands {#c-cremaref-frappe}

All of these run inside an application and need no running `frappe dev`: they replay the events it kept. A value needs `=`: `--limit=5`, not `--limit 5`.

- `frappe traces [--errors] [--slow=MS] [--limit=N] [--agent|--human]`: Recent requests, jobs and schedule runs, newest first. `--slow=MS` keeps traces of at least that many milliseconds; `--errors` keeps failed ones. `--limit` defaults to 20. Always exits 0.
- `frappe trace REF [--md]`: One trace, or an error outside any trace. REF is `last`, `last-error` or a prefix of at least 6 characters of a trace id, a request id or the fingerprint of the error the trace ended with, or of an error outside a trace. `--md` adds sections for the error, backtrace, queries, logs, dumps and, when Latte holds spans from other services, `Across services`. A miss exits 1.
- `frappe errors [--agent|--human]`: Errors and repeated queries since the newest successful build, grouped. With `--agent` each is an MRDP block and the exit is 1 if any is printed; otherwise `OK errors 0`.
- `frappe logs [app|compiler|access] [--follow]`: The last 200 lines of a site log, through `tail`; `access` is the proxy’s. A missing log exits 1.
- `frappe db diagnose`: Builds a development binary and runs its `db diagnose` against the development database.

- `ERR RUNTIME:STATUS`: One per error group since the newest good build, `:500` for requests. `MSG` gives the class, message and count; `FIX` points at `frappe trace FINGERPRINT --md`.
- `ERR REPEATED_QUERY`: One per route and statement that ran five or more times in one request, with the most runs shown. `FIX` suggests preloading the association.

Frappé keeps the newest 500 traces, 200 standalone errors and 50 builds, in `events.jsonl` in the site’s log folder, which rolls at 8 MiB into one `.previous` file.

## What Latte adds {#c-cremaref-latte}

- `PostgreSQL`: Latte’s PostgreSQL loads `pg_stat_statements` (top-level statements, no utility commands) and `auto_explain` (plans of statements over 250 ms, without timings or parameters, in `postgres.log`). The `caramel_stats` schema exists in the development database only, and `frappe db dump` leaves it out.
- `Access log`: Caddy writes one JSON line for each request to the site’s `access.log`, mode 0600, rolling at 1 MB with one previous file. It is kept out of `proxy.log`.
- `Collector`: Latte listens on `127.0.0.1:4318` for `POST /v1/traces` with JSON only. It rejects bodies over 4 MiB, keeps the newest 2,000 traces in memory, 200 spans per trace and 32 attributes per span, and forgets them when it stops. If the port is busy, `frappe services` reports the collector as unavailable and everything else works.
- `Control API 2`: `GET /v2/status` adds the collector’s state; `GET /v2/traces?limit=N` (default 50, at most 200) and `/v2/traces/ID` read the collector; `GET /v2/sites` adds each site’s error count and last error, which holds a class, a location and a fingerprint, never a message.
- `Menu bar`: Latte.app refreshes every 10 seconds. It shows each site’s error count beside its state and notifies on a new error fingerprint or a build failure. A notification needs permission and opens the inspector.

## Limits {#c-cremaref-limits}

- `Spans in a trace`: 200; more are counted as dropped.
- `Distinct statements tracked for repeats`: 500 in a trace; five runs make a repeat.
- `Error ring`: 500 fingerprints; the least recently seen is evicted.
- `Trace ring`: 200 traces.
- `Metric series`: 1,000 distinct request series.
- `Tails`: 8 at once, 1,000 events buffered for each.
- `Histogram bounds`: 5, 10, 25, 50, 100, 250, 500, 1,000, 2,500, 5,000 and 10,000 milliseconds, and overflow.

> **Nothing here is stored for you**
>
> Logs, tail events, metric labels, exports and database tables carry no exception message, bind value or request body. Messages and backtraces stay in memory and in development surfaces, so forward `Crema.on_error` reports to an error tracker if you need history.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Review the security defaults →](https://caramelize.dev/docs/0.14.0/security/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/crema/
