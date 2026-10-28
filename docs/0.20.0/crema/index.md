Reference / Crema

# See what your application did.

Crema is Caramel’s observability: request ids, one log line for every request, job and schedule run, error reports, an owner-only ops socket, an opt-in recorder and exporter, and the development tools.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | A Caramel application; the recorder and exporter are opt-in requires |
| Covers | Request ids, the log line, error reports, the ops socket, metrics, the recorder, the OTLP exporter and the development tools |
| Proved by | `frappe traces --agent` · `frappe trace last --md` · `frappe errors --agent` |

Learning it for the first time? The guide [Know what your application did](https://caramelize.dev/docs/0.20.0/observability/index.md) walks through it in order. This page lists every name, field, variable and limit.

## Limits at a glance {#c-cremaref-limits}

| Limit | Value |
| --- | --- |
| Inbound `X-Request-ID` | 8–128 characters |
| Slow request, default | 1 second |
| Slow job or schedule run, default | 5 seconds |
| Slow query, default | 100 milliseconds |
| Runs that make a repeated statement | 5 |
| Spans in a trace (more are counted as dropped) | 200 |
| Distinct statements tracked for repeats in a trace | 500 |
| Span detail kept in the trace ring | 2,048 bytes |
| Log entry kept as a span | 1,000 bytes |
| Binds kept per statement, each cut at | 20, 200 bytes |
| **Copy with values** literal; longer stays `$n` | 2,000 bytes |
| Error report backtrace | 50 frames of 2,048 bytes |
| Error report message | 8,192 bytes |
| Causes listed | 5 |
| Error ring (least recently seen is evicted) | 500 fingerprints |
| Trace ring | 200 traces |
| `/v1/traces` and `/v2/traces` limit | default 50, at most 200 |
| Concurrent tails (events buffered for each) | 8 (1,000) |
| Tail keep-alive `: ping` | every 15 seconds |
| Ops connection read and write timeout | 10 seconds |
| `POST /v1/debug-tokens` minutes | 1–120, default 15 |
| `POST /v1/debug-tokens` body | 1 KiB |
| Debug token lifetime | 2 hours |
| Distinct request series (the rest fold into `(other)`) | 1,000 |
| Recorder keys of each kind per flush | 500 |
| Recorder SQL key | 500 bytes |
| Recorder flush interval | 15 seconds |
| Recorder retention (pruned hourly) | 7 days |
| Recorder histogram | 12 buckets: 5, 10, 25, 50, 100, 250, 500, 1,000, 2,500, 5,000, 10,000 ms and overflow |
| `APP insights` rows | 20 |
| Exporter queue | 2,048 traces |
| Exporter batch | every 5 seconds or at 512 spans |
| Exporter timeouts | 5 seconds connect, 10 seconds read |
| Error page frames | 80 |
| Source file shown in the error page | 1 MiB |
| `dump` span | 8,192 bytes |
| Inspector traces listed | 500 |
| Toolbar request list | last 10 |
| `frappe traces --limit` default | 20 |
| Frappé keeps | 500 traces, 200 standalone errors, 50 builds |
| `events.jsonl` rolls at | 8 MiB |
| Trace or request id prefix | at least 6 characters |
| Database statement and lock timeout, default | 30 s, 5 s (`migrate`: none, 5 s) |
| `auto_explain` threshold | 250 ms |
| `access.log` rolls at | 1 MB |
| Collector body rejected over | 4 MiB |
| Collector memory | 2,000 traces, 200 spans each, 32 attributes per span |

## Crema runs in every application {#c-cremaref-where}

Crema is part of every application. What it does depends on how the process runs and which parts you opt into.

| Mode | What runs |
| --- | --- |
| Always on | A request id and trace for every routed request, job and schedule run; the canonical log line; error reports; the in-memory error and trace rings; the metrics behind `ops metrics`. A `serve` process also opens the ops socket. |
| Opt in | `require "caramel/crema/recorder"` keeps latency history in the database; new applications already have it. `require "caramel/crema/otlp"` exports traces to a tracing backend. |
| Development only | Code compiled with `-D caramel_development`, which `frappe dev`, `frappe check` and one-shot development builds pass, and run with `CARAMEL_ENV=development`: the error page, `dump`, `Server-Timing`, query binds and source lines, and the event sink behind the inspector. |

## Settings are set before the application starts {#c-cremaref-api}

Set these in `config/application.cr`, before the application starts.

| Setting | Meaning |
| --- | --- |
| `Caramel::Crema.slow_request` | `Time::Span`, default 1 second. A request at least this slow is kept in the trace ring as slow and flagged in the toolbar. |
| `Caramel::Crema.slow_job` | Default 5 seconds. Applies to jobs and schedule runs. |
| `Caramel::Crema.slow_query` | Default 100 milliseconds. Each statement at least this slow counts in the log line’s `slow_queries`. |
| `Caramel::Crema.trust_trace_context = false` | Default true. False ignores every inbound `traceparent` and `X-Request-ID`: each request gets fresh ids, no `parent_id` and no caller’s sampling flag. `CARAMEL_TRUST_TRACE_CONTEXT=0` sets it at start. |
| `Caramel::Crema.on_error { \|report\| … }` | Called for every error report, handled or not, with the redacted message and backtrace. |
| `Caramel::Crema.report(error, handled: true, source: nil)` | Reports an error you rescued. It never raises. A handled report writes a WARN line and leaves the trace’s outcome `ok`; `handled: false` marks the trace failed. |
| `Caramel::Crema.measure(kind, name, detail = nil) { … }` | Times a block as a span of the current trace. Kinds: `sql`, `http`, `view`, `enqueue`, `log`, `dump` and `domain`. |
| `Caramel::Crema.command(name, syntax) { \|arguments\| … }` | Adds a command to the application binary and returns its exit code. The first word of the syntax is the name; registering a name again replaces the earlier command. The binary’s usage text lists the syntax. |
| `Caramel::Crema.console_page(segment) { \|request\| … }` | Adds a page at `/segment` to the ops console. The block returns HTML. |
| `Caramel::Crema.subscribe(sink)` | Adds a sink that receives finished traces and error reports. Remove it with `unsubscribe`. |
| `Caramel.dump(value)` | Development only. See below. |

## Environment variables choose mode, format and socket {#c-cremaref-env}

| Variable | Meaning |
| --- | --- |
| `CARAMEL_ENV` | `development` adds request paths and error messages to log lines. In a development build it also turns on the error page, `dump`, `Server-Timing`, query binds and the literals behind **Copy with values**. `test` and `development` default the log format to text. Unset counts as `production`. |
| `CARAMEL_LOG_FORMAT` | `json` or `text`. Any other value falls back to text in development and test, JSON elsewhere. |
| `LOG_LEVEL` | Default `Info`. Applies to every log source, not only `crema`. |
| `CARAMEL_OPS_SOCKET` | A path for the ops socket, or `off`. Unset, a `serve` process uses its `CARAMEL_SOCKET` path with `.sock` replaced by `.ops.sock`. A `work` process opens a socket only when this names a path. The `ops` client reads the same variables. Its key file sits beside it as `PATH.key`. |
| `CARAMEL_EDITOR` | An editor preset or a link template. See the development section. |
| `CARAMEL_PROJECT_ROOT` | The project root, default the current directory. Error locations are shown relative to it, and its `app`, `config`, `src` and `db` folders count as your code. |
| `APP_SECRET` | The application secret. Debug tokens are signed with a key derived from it alone, so rotating it ends every token; `APP_SECRET_PREVIOUS` does not keep them. |
| `CARAMEL_DEV_EVENTS` | Set by `frappe dev` for development builds: the socket the application sends its events to. Do not set it yourself. |
| `CARAMEL_STATEMENT_TIMEOUT`, `CARAMEL_LOCK_TIMEOUT` | PostgreSQL’s `statement_timeout` and `lock_timeout` on every pooled connection of every command but `migrate`: whole seconds, 0 to 86400, default 30 and 5. `migrate` reads `CARAMEL_MIGRATION_STATEMENT_TIMEOUT` and `CARAMEL_MIGRATION_LOCK_TIMEOUT`, default 0 and 5. 0 means none. Cold Brew’s pool reads the runtime pair. |
| `CARAMEL_POOL_SIZE`, `CARAMEL_POOL_TIMEOUT` | Connections a command’s pool holds, 1 to 32, default 4, and seconds a checkout waits for a free one, 1 to 300, default 5. An invalid value exits 1 with one line naming it. |
| `OTEL_*` | Seven variables read by the exporter; see below. |

| Condition | Outcome |
| --- | --- |
| `CARAMEL_ENV` set to anything but `development`, `test` or `production` | stops every database command with `CARAMEL_ENV must be development, test or production` |
| A timeout variable that is not a whole number of seconds from 0 to 86400 | stops the command with `KEY must be a whole number of seconds from 0 to 86400` |
| A statement past `statement_timeout` | is cancelled by PostgreSQL, which reports it before the pool’s own read timeout |

## Every traced response carries a request id {#c-cremaref-ids}

| Condition | Outcome |
| --- | --- |
| Inbound `X-Request-ID` of 8 to 128 characters from `A-Z a-z 0-9 . _ : -` | kept |
| Any other inbound `X-Request-ID` | replaced by a UUID |
| Static files, and the 400 and 421 refusals | not traced, and carry no id |
| `traceparent` with version `00`, lowercase hex, a 32-digit trace id, a 16-digit parent id and flags | continues the caller’s trace and supplies the log line’s `trace_id` and `parent_id`; the first flag bit says whether the caller sampled it |
| A `traceparent` with all-zero ids | ignored |
| `enqueue` | stores the traceparent, the request id and the debug flag in `caramel_jobs.context`, never a message; the job continues that trace |
| A schedule run, or a missing or malformed job context | starts a new trace |
| Each `Caramel::Outbound` call | is an `http` span named `METHOD host`, and sends a `traceparent` unless you set one |
| A debug trace | sends `X-Caramel-Trace` with the trace id |

## Every finished trace writes one log line {#c-cremaref-log}

The `crema` log source writes one INFO line for each finished trace, named `request`, `job` or `schedule`.

| Field | Present when |
| --- | --- |
| `name` | Always. `GET /books/:id`, the job class or the schedule name. An unrouted request is `GET (none)`; a method outside GET, HEAD, POST, PUT, PATCH, DELETE and OPTIONS is `OTHER`. |
| `request_id`, `trace_id`, `parent_id` | The ids above. `parent_id` only with a valid inbound or stored traceparent. |
| `duration_ms`, `outcome` | Always. `outcome` is `error` after an unhandled error or a 500, or when a job’s `perform` raised, even if it will retry. |
| `method`, `route`, `action`, `status`, `bytes`, `streamed` | Requests. `route` and `action` only when a route matched; `bytes` is left out for a streamed response. |
| `path` | Requests, only when `CARAMEL_ENV=development`. |
| `job_id`, `queue`, `attempt`, `queue_lag_ms` | Jobs. The lag is the time past `run_at`, never negative. |
| `db_count`, `db_ms`, `db_wait_ms` | Statements, their time, and the wait for a pooled connection. |
| `view_ms`, `outbound_count`, `outbound_ms` | The outermost view’s time and the `Caramel::Outbound` calls. |
| `cache_hits`, `cache_misses`, `enqueued` | `Caramel::Cache` reads and jobs enqueued. |
| `slow_queries`, `repeated_queries` | Statements past `slow_query`, and distinct statements that ran five or more times. Repeats are counted only when the trace records spans: the ops socket, the recorder or the exporter is on, or the build is for development. A trace keeps at most 200 spans (more are counted as dropped) and tracks at most 500 distinct statements for repeats. |
| `debug` | `true` for a debug trace. |
| `error_class`, `fingerprint` | Only when the trace ended in an unhandled error. |

| Condition | Outcome |
| --- | --- |
| A field with no value | is left out |
| Any log entry written inside a trace | also carries `trace_id` and `request_id` |
| A log entry written inside a trace that records spans | is kept as a `log` span of up to 1,000 bytes |
| A slow request or job | shows in the trace ring, the toolbar and the inspector; there is no `slow` field. A slow statement counts in `slow_queries` |

| Form | Shape |
| --- | --- |
| error line | One `error` entry for each report: WARN when handled, ERROR when not. Fields: `error_class`, `fingerprint`, `location` (relative `file:line`), `source` (the trace name, or `stream` or `cold_brew.worker`, `.maintenance`, `.scheduler`, `.hooks NAME`), `handled`, `request_id` and `trace_id`. The `message` is added only when `CARAMEL_ENV=development`. |
| JSON | One object per line: `ts` (UTC, milliseconds), lowercase `level`, `source`, `msg`, then the fields. A field named like one of those four is written as `data_NAME`, so an error’s `source` becomes `data_source`. The default outside development and test. |
| text | `HH:MM:SS.mmm LEVEL` and a one-line summary with one decimal per time: `12:00:00.123 INFO request GET /books/1 200 12.4ms db=3/4.1ms view=2.0ms App::Books::Show request_id=8b1f`; outside development the route `/books/:id` stands where the path is. Values with spaces are quoted. A control character in a message, source or value is written as `\n`, `\r`, `\e` or `\xNN`, and the value is quoted. The default in development and test. |

## Error reports are redacted and stay in memory {#c-cremaref-errors}

| Part | Content |
| --- | --- |
| Fields | `error_class`, `message`, `backtrace` (at most 50 frames of 2,048 bytes), `fingerprint`, `location`, `handled`, `source`, `request_id`, `trace_id`, `occurred_at` and the classes of up to five causes. A message is cut to 8,192 bytes. |
| Fingerprint | The first 12 hex digits of a SHA-256 over the error class, the path of the first frame in your own code and its method name. With no such frame, the first parseable frame; with none, the class alone. Lines, columns and messages are never hashed. |
| Redaction | Applied to every message and backtrace frame: values of environment variables whose names contain `SECRET`, `PASSWORD`, `TOKEN`, `API_KEY` or `DATABASE_URL` become `[redacted]`; PostgreSQL URLs become `[database URL redacted]`; the `user:password@` of any other URL becomes `[credential redacted]@`; a `Cookie` or `Set-Cookie` header becomes `Cookie: [credential redacted]` to its end of line; the values of PostgreSQL’s `Key (email)=(…)` detail become `([redacted])`; `name=value`, `name: value` and JSON pairs whose name holds password, secret, token, api key, access key, private key, credential or authorization, and bare `Bearer` tokens, become `[credential redacted]`. If redaction fails the report keeps its class and the message `[unavailable]`. |
| Where it lives | A report’s message and backtrace exist in memory: the ring behind `ops errors`, and development surfaces. Crema’s logs, tail events, metric labels, exports and `caramel_metrics` carry the class and fingerprint, never the message. The ring holds 500 fingerprints; the least recently seen is evicted. |

| Condition | Outcome |
| --- | --- |
| A job’s failed run | is written unredacted by Cold Brew to `caramel_jobs.last_error`: the class, the message and the first 12 backtrace lines; `APP jobs show ID` prints it |
| A process restart | clears the error and trace rings; forward `Crema.on_error` reports to an error tracker for history |

> Not stored **Messages and backtraces never reach logs, exports or the recorder.**
>
> They stay in memory and in development surfaces. Only `caramel_jobs.last_error`, which Cold Brew writes, keeps a job’s message on disk.

## Every statement in a trace starts with a tag {#c-cremaref-sql}

Every statement run inside a trace starts with a comment: `/*action='App%3A%3ABooks%3A%3AShow'*/` for a request, `/*job='…'*/` for a job and `/*schedule='…'*/` for a schedule. The value is the action or job class or the schedule name, percent-encoded. Pools name themselves in `application_name`: `caramel-web` for `serve`, `caramel-cold-brew` for workers and `caramel-listen` for PubSub.

| Condition | Outcome |
| --- | --- |
| A statement run outside a trace | carries no tag |
| A statement’s binds in a development build | are kept for the inspector: at most 20, each cut at 200 bytes, `NULL` for nil |
| A span’s detail in the trace ring | is cut at 2,048 bytes |
| A statement over `slow_query` | counts in the log line’s `slow_queries` |

## The ops socket answers its owner only {#c-cremaref-ops}

An HTTP/1.1 server on a Unix socket, for the application’s owner.

| Condition | Outcome |
| --- | --- |
| A directory that is not a real directory you own with no group or other permissions | stays off: the application keeps serving, and the log says why |
| The socket file | is mode 0600 |
| A live socket | is never replaced; a dead one is |
| Each connection | has a 10-second read and write timeout |
| A tail with nothing to send for 15 seconds | sends `: ping` to keep the connection open |
| A request whose `Host` is not `ops`, `localhost`, `127.0.0.1` or `[::1]` | answers 421 |
| A request without the key, or with a wrong one | answers 401 |
| The key file `SOCKET.key` | is mode 0600, new at each start, removed at stop |
| The `caramel_ops` cookie | is accepted on GET only |
| `GET /?key=KEY` | answers 303 to `/` and sets the cookie |
| A write with an `Origin` header | answers 403 |
| A wrong method | answers 404 |
| A ninth concurrent tail | answers 429 |
| `POST /v1/debug-tokens` without an application secret, which a `work` process lacks | answers 404 |
| Every answer | is JSON with a `version` and carries `Cache-Control: no-store` |

| Endpoint | Answers |
| --- | --- |
| `GET /v1/status` | App, role, uptime, environment, in-flight work, request counts and p95, memory, database pools, workers, scheduler, sinks and dropped events. |
| `GET /v1/requests`, `/v1/fibers` | In-flight requests and jobs; fibers grouped by name. |
| `GET /v1/metrics` | Prometheus text. |
| `GET /v1/tail` | Server-sent events of finished traces and errors. Query: `errors=1`, `slow=MS`, `logs=1`. At most 8 at once, 1,000 events buffered for each. A debug trace always passes the filters. With `logs=1` the events include log lines exactly as written to stdout. |
| `GET /v1/errors`, `/v1/errors/FINGERPRINT` | Errors since the process started, grouped, newest first. The second route is the only one that returns a message and backtrace. |
| `GET /v1/traces?limit=N&reason=error\|slow\|debug` | The trace ring, 50 by default, at most 200. A trace is kept when it failed, was slow or carried a debug token. The ring holds 200 traces. |
| `GET /v1/traces/REF` | One trace with its spans. REF is a prefix of at least 6 characters of a trace id or request id. |
| `POST /v1/debug-tokens` | JSON `{"minutes": N}`, 1 to 120, default 15, in a body of at most 1 KiB. |

Direct callers send the key as a bearer token: `curl --unix-socket SOCKET -H "Authorization: Bearer $(cat SOCKET.key)" http://ops/v1/status`. Prometheus reads it with `authorization: credentials_file: SOCKET.key`.

The read-only console is the same data as HTML at `/`, `/requests`, `/tail`, `/jobs`, `/database`, `/errors`, `/traces` and `/insights`. It can neither retry a job nor issue a token, and its content security policy allows only its own scripts and styles.

## Binary commands exit 0, 1 or 2 {#c-cremaref-commands}

The commands page lists each one’s syntax; these are the details. Run `ops` where the process runs; `--socket=PATH` works on every subcommand.

[See every command →](https://caramelize.dev/docs/0.20.0/commands/index.md)

| Command | Does |
| --- | --- |
| `ops status` | Seven lines: `App`, `Requests`, `Jobs`, `Database`, `Memory`, `Fibers` and `Crema`. `--json` prints the status document. |
| `ops requests`, `ops fibers` | In-flight work; fibers by name. |
| `ops metrics` | Prometheus text, as served. |
| `ops tail` | Streams until you stop it. `--slow` takes a value here, and `MS` must be an integer. |
| `ops errors` | Fingerprint, count, last seen, class, location and source. |
| `ops error FINGERPRINT` | One error with its redacted message and backtrace. A miss says that restarts clear the rings. |
| `ops traces` | One reason flag; errors win over slow, slow over debug. The reason flags take no value. |
| `ops trace REF` | One trace as text, or Markdown with `--md`. |
| `ops debug-token` | Prints the token, its expiry, a `curl` line with the header and a browser line that sets the cookie. |
| `ops console` | Prints `ssh -N -L 8765:SOCKET HOST` and `http://localhost:8765/?key=KEY`. It does not connect. |
| `jobs`, `jobs stats` | Each queue’s running, retrying, queued, scheduled and failed jobs, the finished in the last hour and the age of the oldest due job. |
| `jobs failed` | Failures grouped by job class and error class, newest first; `--limit` defaults to 20. |
| `jobs show ID` | Every column of one job, including `last_error` and `context`. It prints to your terminal only. |
| `jobs retry ID`, `jobs retry --class=NAME` | Writes to the database: clears the failure and runs the job once more, an abandoned job included. It keeps `attempts`. |
| `jobs unknown` | The queued job classes this binary does not compile, one per line, for a deploy to check before the binary takes over. |
| `db diagnose` | Sections `connections`, `long_running` (over 1 second), `blocking`, `cache_hit`, `seq_scans`, `unused_indexes`, `vacuum`, `table_sizes` and `outliers` (the slowest statements of your role, from `pg_stat_statements`). |
| `db roles DATABASE MIGRATION_ROLE RUNTIME_ROLE` | Prints a psql script that creates the two login roles, the database the migration role owns and the grants Latte gives a site: the runtime role reads and writes rows through default privileges. It sets no passwords, grants both roles to the role that runs it, and stops, before any grant, when a role that already exists has SUPERUSER, CREATEDB, CREATEROLE, BYPASSRLS or REPLICATION. Run it with `psql -v ON_ERROR_STOP=1`; revoke the memberships when you finish. It needs no database. Names match `[a-z_][a-z0-9_]*`, up to 63 characters. |
| `insights` | The recorder’s top 20 rows by count under the headers `KEY COUNT ERR P50MS P95MS MAXMS TOTAL_S`. `--since` defaults to `1h`, `--kind` to `request`. |

| Condition | Outcome |
| --- | --- |
| Exit status | 0 is success, 1 a failure or nothing found, 2 a usage error |
| `ops` with no key file beside the socket | exits 1 with `No ops key at PATH.key. Run ops as the user that runs the application.` |
| `ops` with no socket at the path | exits 1 with `No ops socket at PATH. Is the application running with CARAMEL_OPS_SOCKET?` |
| `ops errors` | shows UTC times; `ops traces` and `ops tail` show local times |
| `ops traces --slow=500`, a reason flag with a value | exits 2, a usage error |
| `ops tail --slow` without a value | exits 2, a usage error |
| `jobs`, `db diagnose` and `insights` | need `DATABASE_URL` and no running application |
| `jobs` with `CARAMEL_ENV=test` | refuses |
| `insights` without the recorder | exits 1 with `The Crema recorder is off. Add require "caramel/crema/recorder" to config/application.cr.` |
| `insights` with no rows in the window | prints `No aggregates in the last 1h. Is the recorder running?` and exits 0 |
| `jobs unknown` when any class is unknown | exits 1; with no `caramel_jobs` table yet, it prints nothing and exits 0 |
| `db diagnose` with an unreadable section | says so and the rest continue; exits 0 if any section was readable |
| `db roles` with a name that does not match `[a-z_][a-z0-9_]*` up to 63 characters | exits 2 |

## Metrics count from the process start {#c-cremaref-metrics}

| Condition | Outcome |
| --- | --- |
| A request route | is a route template; an unmatched route is `(none)` |
| More than 1,000 distinct request series | fold into `(other)` |
| Values | count from the process start and are not stored |
| Durations | are histograms in seconds with bounds from 0.005 to 10 and `+Inf` |

| Metric | Type and labels |
| --- | --- |
| `caramel_requests_total` | counter: `method`, `route`, `status`. |
| `caramel_request_duration_seconds` | histogram: `method`, `route`. |
| `caramel_jobs_total` | counter: `job`, `outcome`. |
| `caramel_job_duration_seconds` | histogram: `job`. |
| `caramel_job_queue_lag_seconds` | histogram: `queue`. |
| `caramel_schedules_total` | counter: `schedule`, `outcome`. |
| `caramel_errors_total` | counter: `error_class`. |
| `caramel_inflight` | gauge: `kind` is request, job or schedule. |
| `caramel_gc_heap_bytes`, `caramel_gc_free_bytes` | gauges for the Crystal heap. |
| `caramel_gc_allocated_bytes_total` | counter of bytes allocated. |
| `caramel_fibers` | gauge: fibers alive. |
| `caramel_db_pool_connections` | gauge: `pool`, `state` is open, idle or in_flight. |
| `caramel_db_pool_max` | gauge: `pool`, the pool’s limit. |
| `caramel_crema_dropped_total` | counter: `sink`, events a sink lost. |
| `caramel_build_info` | gauge, always 1: `app`, `caramel`. |
| `caramel_process_start_time_seconds` | gauge: when the process started. |

## Debug tokens expire within two hours {#c-cremaref-debug}

A token is `EXPIRY.SIGNATURE`: the expiry as Unix seconds and an HMAC-SHA-256 of it, keyed from the application secret.

| Condition | Outcome |
| --- | --- |
| A token | is valid until its expiry and never longer than two hours, whatever it claims |
| The `X-Caramel-Debug` header and the `__Host-caramel_debug` cookie both sent | the header wins |
| An invalid `X-Caramel-Debug` header | is not replaced by the cookie |
| A valid token | traces the request in full, answers with `X-Caramel-Trace`, keeps it in the trace ring with the reason `debug`, always exports it when the exporter is on, and passes it to the jobs it enqueues |
| A token that leaks | stays valid until it expires, because the signature covers only the expiry |

## The recorder stores aggregates, never a path or a message {#c-cremaref-recorder}

| Condition | Outcome |
| --- | --- |
| `require "caramel/crema/recorder"` | aggregates each finished trace in memory and writes to `caramel_metrics` |
| Upgrading | run `frappe migrate`, since `caramel_metrics` comes with Cold Brew’s framework tables |
| What is stored | route templates, job classes, schedule names, parameterized SQL and outbound hosts, never a path, a bind value, a message or a trace |
| More than 500 keys of one kind per flush | fold into `(other)` |
| A failed flush | loses its batch, writes one warning and counts toward `caramel_crema_dropped_total` |

| Name | Meaning |
| --- | --- |
| `caramel_metrics` | `bucket` (the start of the minute), `kind`, `key`, `count`, `errors`, `total_ms`, `max_ms` and `histogram`, a 12-bucket latency count with bounds 5, 10, 25, 50, 100, 250, 500, 1,000, 2,500, 5,000 and 10,000 ms, and overflow. The primary key is (`bucket`, `kind`, `key`). Rows merge by adding counts and keeping the larger maximum. |
| `kind` | `request`, `job`, `schedule`, `sql` or `outbound`. |
| `SQL keys` | Quoted literals and bare numbers become `?`, `IN (…)` lists become `IN (?)`, whitespace collapses, and the key is cut to 500 bytes. |
| `Caramel::Crema::Recorder.flush_interval` | Default 15 seconds. Each flush upserts into the current minute. |
| `Caramel::Crema::Recorder.retention` | Default 7 days. Pruned hourly. |

## The exporter sends nothing until an endpoint is set {#c-cremaref-otlp}

`require "caramel/crema/otlp"` exports each sampled request, job and schedule run as OTLP over HTTP with JSON bodies, with a child span for every query and outbound call.

| Condition | Outcome |
| --- | --- |
| No endpoint set | nothing is sent |
| Protobuf | not supported |
| An `OTEL_*` variable other than the seven listed | not read |
| `OTEL_EXPORTER_OTLP_PROTOCOL` other than unset or `http/json` | logs a warning and leaves export off |
| An `http://` endpoint off `127.0.0.1`, `::1` or `localhost` with `OTEL_EXPORTER_OTLP_HEADERS` set | warns once, `OTLP headers are sent in clear to HOST; use an https endpoint`, and exports |
| An unknown `OTEL_TRACES_SAMPLER` | warns and uses `traceidratio` |
| A parent-based sampler | follows the caller’s flag when there is one and `trust_trace_context` is on |
| A failed trace that sampling skipped | is exported as its root span |
| A debug trace | is always sampled |
| A failed batch | is dropped, counted, and logged at most once a minute |

| Variable | Meaning |
| --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | The base URL; `/v1/traces` is appended. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Used as given, and wins over the base. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | Unset or `http/json`. |
| `OTEL_EXPORTER_OTLP_HEADERS` | Comma-separated `name=value` pairs, percent-decoded. |
| `OTEL_SERVICE_NAME` | Default: the application’s title. |
| `OTEL_TRACES_SAMPLER` | `always_on`, `always_off`, `traceidratio` (the default), `parentbased_always_on`, `parentbased_always_off` or `parentbased_traceidratio`. |
| `OTEL_TRACES_SAMPLER_ARG` | The ratio, 0 to 1; default 1. |

| Part | Behaviour |
| --- | --- |
| Spans | A request is a server span, a job a consumer span and a schedule an internal span; queries and outbound calls are client spans. `log` and `dump` spans are never exported. Attributes are route templates, `db.query.text` with the SQL normalised (quoted and dollar-quoted strings and bare numbers become `?`, `$n` binds stay, comments go, whitespace collapses) and cut to 500 bytes, the HTTP method and status, the job’s queue, id and attempt, and `caramel.request_id`. A failed trace adds the exception’s class only. |
| Sampling | Decided once per trace. |
| Delivery | Up to 2,048 traces wait in memory and go out every 5 seconds or at 512 spans, with a 5-second connect and 10-second read timeout. |

## Development tools need a development build {#c-cremaref-dev}

| Condition | Outcome |
| --- | --- |
| A binary built without `-D caramel_development`, or run without `CARAMEL_ENV=development` | holds none of these tools; a check confirms a production binary holds none of it |
| An unrecognised `CARAMEL_EDITOR` | falls back to `zed` |
| `Server-Timing` on a streamed response | is not sent |

| Tool | Behaviour |
| --- | --- |
| Error page | An unhandled error answers 500 with the class, the redacted message, up to 80 frames with Open in editor links, four lines of source either side of your first frame (files under `app`, `config`, `src` or `db` up to 1 MiB), the request, the queries before the error and the causes. A client that asks for JSON first gets an `error` object with the class, message, location, request and trace ids and backtrace instead. |
| `dump(value)` | Prints `dump file:line: value` to standard error and returns the value; inside a trace it adds a `dump` span of up to 8,192 bytes. In actions, views and jobs, and as `Caramel.dump`. In other builds it returns the value untouched. |
| `Server-Timing` | `db;dur=…;desc="N queries", view;dur=…, total;dur=…`. |
| Toolbar | `frappe dev` adds it to full HTML responses that carry an `X-Request-ID`, not to htmx partials, the build-error page or the inspector. It shows the route, status, time and query count, flags for errors, slow requests and repeated queries, and the last ten requests. Each part links to `#timeline`, `#queries` or `#error` on the request’s page (the Timeline and Queries sections are on the page even when empty and say so; the Error section is there for a failed request). The minimise button shrinks it to a dot, and the dot restores it. `` ` `` opens and closes the list, `j` and `k` move in it, `Esc` closes it; shortcuts are ignored in fields and with a modifier key. **Copy for an agent** fetches `/__caramel/dev/trace.md?id=ID` (a hexadecimal id of 6 to 32 characters; it needs the development session cookie and answers 403 without it). **Theme** cycles auto, light and dark. It polls every 400 ms and reloads when the build changes. |
| Inspector | `/__caramel/dev/inspector` lists up to 500 traces, filtered by `?only=errors`, `slow` or `jobs`. Beside it: `/inspector/traces/ID` (a prefix of at least 6 characters), `/inspector/errors` and `/inspector/builds`. Each query on a trace page has **Copy SQL** and **Copy with values**; the values come from literals built when the query ran (numbers and booleans bare, text, times and bytes quoted, `nil` as `NULL`, arrays as `ARRAY[…]`) and never leave development. Placeholders without a value stay as `$n`. The page follows the system’s light or dark appearance; the Theme button sets it for the toolbar and the inspector together (`localStorage` key `caramel.dev.theme`). Its pages need the development session cookie, which only the single-use sign-in link sets, and answer 403 without it. Its endpoints answer GET only and check the host. |
| `CARAMEL_EDITOR` | A preset or a template with `{path}`, `{line}` and `{column}`. Presets: `zed` (the default), `vscode`, `cursor`, `sublime`, `textmate` and `idea`. `frappe dev` also reads it from the project’s `.env`. |
| `Caramel/Dump` | `frappe lint` reports any call to `dump` without a receiver or on `Caramel`, including your own method of that name. The rule is on in new applications’ `.ameba.yml`. |

## Frappé commands replay kept events {#c-cremaref-frappe}

All of these run inside an application and need no running `frappe dev`: they replay the events it kept. A value needs `=`: `--limit=5`, not `--limit 5`.

| Command | Does |
| --- | --- |
| `frappe traces [--errors] [--slow=MS] [--limit=N] [--agent\|--human]` | Recent requests, jobs and schedule runs, newest first. `--slow=MS` keeps traces of at least that many milliseconds; `--errors` keeps failed ones. `--limit` defaults to 20. `--agent` ends with `OK traces N`. |
| `frappe trace REF [--md]` | One trace, or an error outside any trace. REF is `last`, `last-error` or a prefix of at least 6 characters of a trace id, a request id or the fingerprint of the error the trace ended with, or of an error outside a trace. `--md` adds sections for the error, backtrace, queries, logs, dumps and, when Latte holds spans from other services, `Across services`. |
| `frappe errors [--agent\|--human]` | Errors and repeated queries since the newest successful build, grouped. |
| `frappe logs [app\|compiler\|access] [--follow]` | A site log through `tail`; `access` is the proxy’s. The Local environment page gives the line count and the folder. |
| `frappe db diagnose` | Builds a development binary and runs its `db diagnose` against the development database. |

| Condition | Outcome |
| --- | --- |
| `frappe traces` | always exits 0 |
| `frappe trace REF` with no match | exits 1 |
| `frappe errors --agent` with any group | prints one MRDP block each and exits 1; otherwise it prints `OK errors 0` |
| `frappe logs` with a missing log | exits 1 |
| Stored events | the newest 500 traces, 200 standalone errors and 50 builds, in `events.jsonl` in the site’s log folder; at 8 MiB it rolls into one `.previous` file |

| Diagnostic | Meaning |
| --- | --- |
| `ERR RUNTIME:STATUS` | One per error group since the newest good build, `:500` for requests. `MSG` gives the class, message and count; `FIX` points at `frappe trace FINGERPRINT --md`. |
| `ERR REPEATED_QUERY` | One per route and statement that ran five or more times in one request, with the most runs shown. `FIX` suggests preloading the association. |

## Latte adds statistics, an access log and a collector {#c-cremaref-latte}

| Part | Adds |
| --- | --- |
| PostgreSQL | Latte’s PostgreSQL loads `pg_stat_statements` (top-level statements, no utility commands) and `auto_explain` (plans of statements over 250 ms, without timings or parameters, in `postgres.log`). The `caramel_stats` schema exists in the development database only, and `frappe db dump` leaves it out. |
| Access log | Caddy writes one JSON line for each request to the site’s `access.log`, mode 0600, rolling at 1 MB with one previous file. It is kept out of `proxy.log`. |
| Collector | Latte listens on `127.0.0.1:4318` for `POST /v1/traces` with JSON only. It answers 421 to a request whose `Host` is not `127.0.0.1`, `localhost` or `[::1]` with its port, rejects bodies over 4 MiB, keeps the newest 2,000 traces in memory within 64 MiB in all, 200 spans per trace and 32 attributes per span, and forgets them when it stops. If the port is busy, `frappe services` reports the collector as unavailable and everything else works. |
| Control API 2 | `GET /v2/status` adds the collector’s state; `GET /v2/traces?limit=N` (default 50, at most 200) and `/v2/traces/ID` read the collector; `GET /v2/sites` adds each site’s error count and last error, which holds a class, a location and a fingerprint, never a message. |
| Menu bar | Latte.app refreshes every 10 seconds. It shows each site’s error count beside its state and notifies on a new error fingerprint or a build failure. A notification needs permission and opens the inspector. |

Prove it

## Replay what the session kept {#c-cremaref-prove}

Serve the application, open a page in the browser, then read the events `frappe dev` kept. Caramel’s own `scripts/check crema` proves the production side: the JSON request line without a path, the `X-Request-ID` echo, the `traceparent` continuation, an error line without the message, the 0600 ops socket, the 421 on a bad `Host`, the metrics series and the debug token.

**Terminal · inside the application**

```bash
frappe dev --no-open
frappe traces --agent
frappe trace last --md
frappe errors --agent
```

**Passing:** `frappe traces --agent` prints one line per trace, starting `request GET /`, then `OK traces N`, and exits 0. `frappe trace last --md` prints the newest trace as Markdown. `frappe errors --agent` prints `OK errors 0` and exits 0 when nothing failed since the newest successful build; a runtime error prints an `ERR RUNTIME:500` block and exits 1, and `frappe trace last-error --md` then has a `## Backtrace` section.

[← Corretto](https://caramelize.dev/docs/0.20.0/corretto/index.md) · [Review the security defaults →](https://caramelize.dev/docs/0.20.0/security/index.md)

Caramel 0.20.0 · https://caramelize.dev/docs/0.20.0/crema/
