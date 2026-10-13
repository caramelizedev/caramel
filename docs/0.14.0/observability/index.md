Guides / Observability

# Know what your application did.

Every request and job gets a stable id, one log line and, when something fails, a report that stays out of your logs.

## Follow one request {#c-crema-ids}

Every routed request carries `X-Request-ID`. An inbound id of 8 to 128 letters, digits and `._:-` is kept; anything else is replaced by a UUID. A W3C `traceparent` header continues the caller’s trace, and the response, the log line and the error report all name the same ids.

## Read the log line {#c-crema-logs}

Each request, job and schedule run writes one wide line from the `crema` log source: the route template, status, duration, query count and time, view time and, for jobs, the queue and how long the job waited. JSON is the default outside development and test. Set `CARAMEL_LOG_FORMAT=text` or `json` to choose, and `LOG_LEVEL` for the level.

**Production · stdout**

```bash
{"ts":"2026-10-03T12:00:00.123Z","level":"info","source":"crema","msg":"request","name":"GET /books/:id","route":"/books/:id","status":200,"duration_ms":12.4,"db_count":3}
```

Unless `CARAMEL_ENV` is `development`, lines never carry the request path or an exception’s message, and no line carries a query’s bind values: dependency errors can include connection URLs and form values.

## Report errors {#c-crema-errors}

An unhandled error in a request is reported once, with its class, a 12-character fingerprint and the first frame of your own code. The fingerprint ignores lines and messages, so one defect stays one group across deploys. Call `Caramel::Crema.report(error)` for an error you handle, and register a hook to forward reports to an error tracker.

**config/application.cr**

```crystal
Caramel::Crema.on_error do |report|
  Tracker.capture(report.error_class, report.fingerprint, report.message)
end
```

A report’s message and backtrace are redacted of secret-looking environment values, database URLs and `password=…` assignments.

## Set what counts as slow {#c-crema-slow}

A request of one second or more, a job or schedule run of five seconds or more, and a query of 100 milliseconds or more count as slow. Change them in your application’s configuration. A slow request or job is kept for `ops traces --slow` and flagged in the development toolbar; a slow query adds to the log line’s `slow_queries`.

**config/application.cr**

```crystal
Caramel::Crema.slow_request = 500.milliseconds
Caramel::Crema.slow_job = 30.seconds
Caramel::Crema.slow_query = 50.milliseconds
```

## See where a query came from {#c-crema-work}

Every statement your request runs starts with a comment that names the action, such as `/*action='App%3A%3ABooks%3A%3AShow'*/`. `pg_stat_activity` and PostgreSQL’s slow-query log then say which code ran it. Jobs and schedules are tagged `job` and `schedule`, and each pool names itself in `application_name`: `caramel-web`, `caramel-cold-brew` and `caramel-listen`.

A job continues the trace that enqueued it, so its log line carries the same request id and trace id. `Caramel::Outbound` calls send `traceparent` to the service they call. Each log line counts queries, their time, the wait for a pooled connection, view time, outbound calls and cache hits. When the trace records spans (the ops socket, the recorder or the exporter is on, or in development), a statement that repeats five or more times in one request is reported as a repeated query.

## Dump a value while developing {#c-crema-dump}

`dump` prints a value and its file and line to standard error, and returns the value, so it fits inside an expression. It works in actions, views and jobs while `frappe dev` runs, and does nothing in a production build. `frappe lint` reports a `dump` left in the code.

**app/actions/books/show.cr**

```crystal
book = dump(App::Book.find!(contract.id))
```

## Read an error page {#c-crema-errors-dev}

In development an unhandled error shows its class and message, every frame of your own code with an Open in editor link, the source around the failing line, the request, the queries that ran before it and its causes. **Copy as Markdown** copies all of it for a bug report or an agent. A client that asks for JSON first gets the error as JSON: its class, message, location, ids and backtrace. Compiler errors link to the file in the same way. Set `CARAMEL_EDITOR` to `zed` (the default), `vscode`, `cursor`, `sublime`, `textmate`, `idea`, or a template such as `myeditor://open?file={path}&line={line}&column={column}`.

## Inspect requests and jobs {#c-crema-inspector}

Every full HTML page `frappe dev` serves shows a small toolbar with its route, status, time and query count; it flags errors, slow requests and queries repeated five or more times. The inspector at `/__caramel/dev/inspector` lists recent requests, jobs and schedule runs, shows each one’s timeline, queries and logs, groups errors by fingerprint, and lists the builds. Latte’s menu bar app opens it from the site’s menu. The browser’s developer tools also show database and view time through `Server-Timing`.

The toolbar shows a request as parts: route, status, time, queries and flags written as words. Each part links to its place on the request’s page: the query count to the Queries section, the time to the timeline, an error to the error section. Click the arrow, or press `` ` ``, for the recent requests; `j` and `k` move through them, `Esc` closes the list, and the dash shrinks the toolbar to a dot (the choice is kept in `localStorage`). **Copy for an agent** puts the request on the clipboard as Markdown.

On the request’s page each query has **Copy SQL** and **Copy with values**, which writes the bind values into the statement as PostgreSQL literals so you can paste it into `psql`: numbers and booleans bare, text and times quoted, `nil` as `NULL`. A query keeps its first 20 binds, and a literal longer than 2,000 bytes (the value with its quotes) is not kept for copying; each such placeholder stays as `$n`, and the copy starts with a comment saying so. Each query is a card: its statement with one clause per line, and below it each bind beside its `$n`, shown as the copy writes it and cut to 200 bytes; the copy holds the whole value, and the copy keeps the statement as it ran. Pointing at a placeholder or at a bind lights up both. A repeated `SELECT` is highlighted with its source and a likely preload. The toolbar and the inspector follow your system’s light or dark appearance and share one **Theme: auto / light / dark** choice, remembered in the browser; the production console follows the system too, with a button of its own.

## Watch from the menu bar {#c-crema-menu}

Latte’s menu bar app shows each site’s error count beside its state, the newest error in its submenu, and an **Open inspector** item. When a build fails, or the application reports an error it has not reported before in this run, the app counts it beside the cup and posts a macOS notification that opens the inspector. Allow notifications for Latte when macOS asks; without permission only the count appears, and opening the menu clears it. Notifications carry the error’s class and location, never its message.

## Read the proxy’s view of a request {#c-crema-access}

Latte’s HTTPS proxy writes one JSON line per request to the site’s own `access.log`, beside `app.log` and `compiler.log`: status, duration, size, host, URI and response headers, including your application’s `X-Request-Id`. Caddy redacts `Cookie` and `Authorization` and keeps the file to a megabyte and one previous file. It is private to you (mode 0600).

**Terminal**

```bash
frappe logs access
frappe logs access --follow
```

## Follow a trace across sites {#c-crema-collector}

Latte listens on `127.0.0.1:4318`, the OTLP/HTTP port, and keeps the newest 2,000 traces in memory. `frappe dev` sends its application’s traces there under the project’s name. A Caramel site that calls another through `Caramel::Outbound` sends a `traceparent`, so both sites’ spans share one trace id, and the inspector’s trace page and `frappe trace REF --md` add an **Across services** section. Any other service joins by exporting OTLP/HTTP JSON to the same address (a Caramel service needs `require "caramel/crema/otlp"` for that); the collector refuses protobuf. Any local process can write to it, and only you can read it. If another program holds the port, `frappe services` shows the collector as unavailable and everything else works.

**Terminal**

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http/json \
OTEL_SERVICE_NAME=billing ./billing serve
```

## Ask from the terminal {#c-crema-agents}

These commands read the events `frappe dev` kept, whether or not it still runs. `frappe traces` lists recent requests and jobs, newest first; `frappe trace REF` shows one, or with `--md` its Markdown; `frappe errors` groups runtime errors and repeated queries. `REF` is `last`, `last-error`, or a prefix of six or more characters of a trace id, a request id or the fingerprint of the error a trace ended with. With `--agent`, `frappe errors` prints compact MRDP lines. `frappe errors` lists only what happened after the newest successful build, so a rebuild clears the errors it fixed.

**Terminal**

```bash
frappe errors --agent
frappe trace last-error --md
frappe traces --errors --limit=5
```

## Look inside a running application {#c-crema-ops}

Every `serve` process opens a private socket next to its application socket (`CARAMEL_OPS_SOCKET` names another path, or `off` turns it off; a `work` process opens one only when you name a path). Only its owner can use it, and nothing is added to the public listener. The application binary is its own client.

**Terminal · on the server**

```bash
./bookshelf ops status
./bookshelf ops tail --errors --slow=500
./bookshelf ops errors
./bookshelf ops error 9f2c4e1a7b3d
./bookshelf ops traces --slow
./bookshelf ops trace 8b1f6c2a --md
./bookshelf ops metrics
```

`ops errors` lists the errors seen since the process started, grouped by fingerprint; `ops error` prints one with its redacted message and backtrace. These live in memory on the socket and nowhere else, and a restart clears them, so forward `Caramel::Crema.on_error` reports to an error tracker for history. `ops metrics` prints Prometheus text for a scraper that can reach the socket.

## Keep one person’s requests {#c-crema-debug}

`ops debug-token --minutes=15` prints a signed token that lasts at most two hours. A request that sends it as `X-Caramel-Debug`, or in the `__Host-caramel_debug` cookie, is traced in full, answered with `X-Caramel-Trace`, kept for `ops traces --debug` and passed to the jobs it enqueues.

## Open the console {#c-crema-console}

`ops console` prints the `ssh -N -L` line that forwards the socket to your laptop; open `http://localhost:8765/` there. The console is read-only: in-flight work, a live tail, queues, database health, errors and traces. It follows your system’s light or dark appearance; its **Theme** button overrides that and is remembered separately, because the console is another origin. Its trace pages carry no bind values and no **Copy with values** buttons.

## Inspect queues and the database {#c-crema-jobs}

These need a database, not a running application: `jobs` counts each queue’s running, retrying, queued, scheduled and failed jobs; `jobs failed` groups failures by class and error; `jobs show ID` prints one job and its stored error to your terminal; `jobs retry ID` or `jobs retry --class=NAME` gives failed jobs one more run. `db diagnose` (and `frappe db diagnose` in development) reports connections, long queries, locks, cache hit ratios, unused indexes, vacuum health and, when `pg_stat_statements` is installed, the slowest statements.

## Keep latency history {#c-crema-recorder}

Logs say what happened; `insights` says how it has been going. Add the recorder to `config/application.cr` (new applications already have it). It keeps one row per minute for each route, job class, schedule, SQL statement and outbound host in `caramel_metrics`: counts, errors, total and slowest time, and a latency histogram. It stores route templates and parameterized SQL only, never a path, a bind value or an error message. Rows older than seven days are deleted, and a failed write loses that batch without touching your requests.

**config/application.cr**

```crystal
require "caramel"
require "caramel/crema/recorder"
```

**Terminal**

```bash
./bookshelf insights --since=24h
./bookshelf insights --kind=sql --since=1h
```

Run `frappe migrate` once after upgrading: `caramel_metrics` comes with Cold Brew’s framework tables. The console’s Insights page shows the same tables.

## Send traces to a tracing backend {#c-crema-otlp}

Add `require "caramel/crema/otlp"` and set the standard OpenTelemetry variables; the application then exports each sampled request, job and schedule run, with a child span for every query and outbound call, as OTLP over HTTP with JSON bodies. Without `OTEL_EXPORTER_OTLP_ENDPOINT` nothing is sent. Protobuf is not supported: leave `OTEL_EXPORTER_OTLP_PROTOCOL` unset or `http/json`.

**Environment**

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.com
OTEL_EXPORTER_OTLP_HEADERS=x-api-key=SECRET
OTEL_SERVICE_NAME=bookshelf
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1
```

Spans name routes and parameterized SQL, never paths, bind values, log text or error messages. A trace that fails is exported even when sampling would skip it, as its root span. A slow or unreachable collector costs a dropped batch and at most one log line a minute.

[Read the tracing design ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0027-crema-tracing.md) · [Read the production access design ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0028-crema-production-access.md)

[Look up every field, variable and limit →](https://caramelize.dev/docs/0.14.0/crema/index.md)

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/observability/
