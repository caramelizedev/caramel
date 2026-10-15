Guides / Observability

# Know what your application did.

Every request and job gets a stable id, one log line and, when something fails, a report that stays out of your logs.

| Contract | Value |
| --- | --- |
| Needs | A running application. `frappe dev` for the development tools; a database for the queue commands |
| You will have | A request id and one log line for every request and job, and error reports that stay out of your logs |
| Covers | Logs, error reports, the development inspector, the ops socket, the recorder and OTLP export |
| Proved by | `frappe errors --agent` · `ops errors` · `ops metrics` |

This guide teaches each task once and names one example. Every field, variable and limit has its home in the reference.

[Look up every field, variable and limit →](https://caramelize.dev/docs/0.15.0/crema/index.md)

The examples use the Bookshelf application of the Learn path. `./bookshelf` is its binary, `APP` on the commands page, run on the machine where it serves.

## The guide in five stages {#c-crema-map}

20 sections · read in order the first time

- **1 · Follow requests**

  - [Follow one request](#c-crema-ids)
  - [Read the log line](#c-crema-logs)
  - [Report errors](#c-crema-errors)
  - [Set what counts as slow](#c-crema-slow)
  - [See where a query came from](#c-crema-work)
- **2 · Develop**

  - [Dump a value while developing](#c-crema-dump)
  - [Read an error page](#c-crema-errors-dev)
  - [Inspect requests and jobs](#c-crema-inspector)
  - [Watch from the menu bar](#c-crema-menu)
  - [Read the proxy’s view of a request](#c-crema-access)
  - [Follow a trace across sites](#c-crema-collector)
  - [Ask from the terminal](#c-crema-agents)
- **3 · Operate**

  - [Look inside a running application](#c-crema-ops)
  - [Trace one person’s requests](#c-crema-debug)
  - [Open the console](#c-crema-console)
  - [Inspect queues and the database](#c-crema-jobs)
- **4 · Keep history**

  - [Keep latency history](#c-crema-recorder)
  - [Send traces to a tracing backend](#c-crema-otlp)
- **5 · Limits**

  - [What does not compile](#c-crema-refusals)
  - [Not covered yet](#c-crema-gaps)

Stage 1 · Follow requests

## Follow one request {#c-crema-ids}

Every routed request carries `X-Request-ID`: a well-formed inbound one is kept, any other is replaced by a UUID, and a W3C `traceparent` continues the caller’s trace. The response, the log line and the error report all name the same ids, and a job enqueued by the request carries them on.

[Look up the id rules →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## Read the log line {#c-crema-logs}

Each request, job and schedule run writes one wide line from the `crema` log source: its name, its ids, its duration and outcome, and counts of queries, their time, view time, outbound calls, cache reads and jobs enqueued. JSON is the default outside development and test; `CARAMEL_LOG_FORMAT` chooses the format and `LOG_LEVEL` the level. Outside development, no line carries the request path or an exception’s message, and no line ever carries a query’s bind values.

[Look up every field and when it is present →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## Report errors {#c-crema-errors}

An unhandled error in a request is reported once, with its class, a fingerprint and the first frame of your own code. The fingerprint ignores lines and messages, so one defect stays one group across deploys. Call `Caramel::Crema.report(error)` for an error you handle, and register a hook to forward reports, redacted of secrets, to an error tracker.

**config/application.cr · Tracker stands for your error tracker’s client**

```crystal
Caramel::Crema.on_error do |report|
  Tracker.capture(report.error_class, report.fingerprint, report.message)
end
```

The message and backtrace reach the hook, the ops socket and the development tools, and nothing else.

[Look up the report’s fields and redaction →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## Set what counts as slow {#c-crema-slow}

A slow request or job is kept for `ops traces --slow` and flagged in the development toolbar; a slow query adds to the log line’s `slow_queries`. Change the three thresholds in your application’s configuration. A statement that runs past PostgreSQL’s `statement_timeout`, which `CARAMEL_STATEMENT_TIMEOUT` sets, is cancelled and reported as an error instead.

**config/application.cr**

```crystal
Caramel::Crema.slow_request = 500.milliseconds
Caramel::Crema.slow_job = 30.seconds
Caramel::Crema.slow_query = 50.milliseconds
```

[Look up the defaults and the timeout variables →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## See where a query came from {#c-crema-work}

Every statement a request runs starts with a comment that names the action, so `pg_stat_activity` and PostgreSQL’s slow-query log say which code ran it; jobs and schedules are tagged the same way, and each pool names itself in `application_name`. A job continues the trace that enqueued it, `Caramel::Outbound` calls send `traceparent` on, and SweetTalk commands, factories and services are timed as `domain` spans. When the trace records spans, a statement that repeats five or more times in one request is reported as a repeated query.

[Look up the tag and pool names →](https://caramelize.dev/docs/0.15.0/crema/index.md)

Stage 2 · Develop

## Dump a value while developing {#c-crema-dump}

`dump` prints a value with its file and line to standard error and returns the value, so it fits inside an expression. It works in actions, views and jobs while `frappe dev` runs, and does nothing in a production build. `frappe lint` reports a `dump` left in the code.

**app/actions/books/show.cr**

```crystal
book = dump(App::Book.find!(contract.id))
```

## Read an error page {#c-crema-errors-dev}

In development an unhandled error shows its class and message, every frame of your own code with an Open in editor link, the source around the failing line, the request, the queries that ran before it and its causes. **Copy as Markdown** copies all of it for a bug report or an agent. A client that asks for JSON gets the same as JSON. Compile errors link to the file in the same way; `CARAMEL_EDITOR` names the editor.

[Look up the editor presets →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## Inspect requests and jobs {#c-crema-inspector}

Every full HTML page `frappe dev` serves carries a toolbar with the request’s route, status, time and query count, flags for errors, slow requests and repeated queries, and the recent requests. Each part links to its place in the inspector at `/__caramel/dev/inspector`, which lists recent requests, jobs and schedule runs with their timeline, queries and logs, groups errors by fingerprint and lists the builds. **Copy for an agent** puts a request on the clipboard as Markdown, and each query has **Copy SQL** and **Copy with values** for `psql`. The browser’s developer tools show database and view time through `Server-Timing`.

[Look up the toolbar’s keys and the copy limits →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## Watch from the menu bar {#c-crema-menu}

Latte’s menu bar app shows each site’s error count beside its state, the newest error in its submenu, and an **Open inspector** item. A failed build or a new error fingerprint counts beside the cup and posts a macOS notification that opens the inspector; allow notifications for Latte when macOS asks. A notification carries the error’s class and location, never its message.

## Read the proxy’s view of a request {#c-crema-access}

Latte’s HTTPS proxy writes one JSON line per request to the site’s own `access.log`, with the application’s `X-Request-Id`, beside `app.log` and `compiler.log`. Caddy redacts `Cookie` and `Authorization`.

**Terminal · inside your application**

```bash
frappe logs access
frappe logs access --follow
```

**Expect:** Prints the last 200 lines of the site’s `access.log`, one JSON line per request with status, duration, size, host, URI and response headers; `--follow` keeps printing. Before the site has served a request it exits 1 with `No access log for NAME yet. Run frappe dev.`

## Follow a trace across sites {#c-crema-collector}

Latte runs a local OTLP collector on `127.0.0.1:4318`, and `frappe dev` sends its application’s traces there. A site that calls another through `Caramel::Outbound` sends a `traceparent`, so both sites’ spans share one trace, and the inspector’s trace page and `frappe trace REF --md` add an **Across services** section. Any other service joins by exporting OTLP/HTTP JSON to the same address; a Caramel service outside `frappe dev` needs `require "caramel/crema/otlp"` for that.

**Terminal · a second Caramel service, billing**

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http/json \
OTEL_SERVICE_NAME=billing ./billing serve
```

**Expect:** `billing` serves as usual and prints nothing about the exporter. After the bookshelf calls it, `frappe trace last --md` in the bookshelf ends with an `## Across services` section that lists `billing`’s spans.

## Ask from the terminal {#c-crema-agents}

These commands read the events `frappe dev` kept, whether or not it still runs: `frappe traces` lists recent requests and jobs, `frappe trace REF` shows one, and `frappe errors` groups runtime errors and repeated queries since the newest successful build, so a rebuild clears the errors it fixed. With `--agent`, or when stdout is not a terminal, they print MRDP.

**Terminal · inside your application**

```bash
frappe errors --agent
frappe trace last-error --md
frappe traces --errors --limit=5
```

**Expect:** `frappe errors --agent` prints `OK errors 0` and exits 0 when nothing failed since the newest successful build; otherwise one `ERR RUNTIME:500` or `ERR REPEATED_QUERY` block per group, and exits 1. `frappe trace last-error --md` prints the failed trace as Markdown with a `## Backtrace` section, and exits 1 when no trace failed. `frappe traces --errors --limit=5` lists the newest five failed traces.

[Look up REF and each flag →](https://caramelize.dev/docs/0.15.0/crema/index.md)

Stage 3 · Operate

## Look inside a running application {#c-crema-ops}

A `serve` process opens a private ops socket next to its application socket; only its owner can use it, and nothing is added to the public listener. `CARAMEL_OPS_SOCKET` moves it, turns it off, or gives a `work` process one. The application binary is its own client.

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

**Expect:** `ops status` prints seven lines, `App`, `Requests`, `Jobs`, `Database`, `Memory`, `Fibers` and `Crema`; the first names the application, its Caramel version, role, pid and uptime. `ops tail` streams finished traces and errors until you stop it. `ops errors` prints a table with `FINGERPRINT COUNT LAST_SEEN CLASS LOCATION SOURCE`, the errors seen since the process started; `ops error FINGERPRINT` prints one with its redacted message and backtrace. `ops traces --slow` lists the kept slow traces and `ops trace REF --md` prints one as Markdown. `ops metrics` prints Prometheus text. Without a running process each exits 1 with `No ops socket at PATH. Is the application running with CARAMEL_OPS_SOCKET?`

Errors live in memory on the socket and nowhere else, so forward `Caramel::Crema.on_error` reports to an error tracker for history. A scraper that can reach the socket can read `ops metrics`.

[Look up the socket’s rules, endpoints and metrics →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## Trace one person’s requests {#c-crema-debug}

`ops debug-token --minutes=15` prints a signed token. A request that sends it as `X-Caramel-Debug`, or in the `__Host-caramel_debug` cookie, is traced in full, answered with `X-Caramel-Trace`, kept for `ops traces --debug` and passed to the jobs it enqueues.

**Terminal · on the server**

```bash
./bookshelf ops debug-token --minutes=15
```

**Expect:** Prints the token and its expiry, a `curl` line that sends the header and a browser line that sets the cookie.

[Look up the token’s lifetime and rules →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## Open the console {#c-crema-console}

The console is the same data as HTML, read-only: in-flight work, a live tail, queues, database health, errors, traces and insights. Its trace pages carry no bind values.

**Terminal · on the server**

```bash
./bookshelf ops console
```

**Expect:** Prints `ssh -N -L 8765:SOCKET HOST` and `then open http://localhost:8765/`. It does not connect: run the `ssh` line on your laptop, then open the address.

## Inspect queues and the database {#c-crema-jobs}

The `jobs` and `db diagnose` commands need the database, not a running application: queue counts, failures grouped by class and error, one job with its stored error, a retry, and PostgreSQL’s own view of connections, locks, cache hits, indexes, vacuum and slow statements. `frappe db diagnose` runs the last one against the development database.

**Terminal · on the server**

```bash
./bookshelf jobs
./bookshelf jobs failed
./bookshelf db diagnose
```

**Expect:** `jobs` prints one row per queue with `running`, `retrying`, `queued`, `scheduled`, `failed`, `finished_1h` and `oldest_due_s`. `jobs failed` prints the newest 20 failure groups with their class, error class, count, last time and newest id. `db diagnose` prints one section per check and exits 0 when any section was readable.

[Look up each command’s columns and exit codes →](https://caramelize.dev/docs/0.15.0/crema/index.md)

Stage 4 · Keep history

## Keep latency history {#c-crema-recorder}

Logs say what happened; `insights` says how it has been going. The recorder keeps one row per minute for each route, job class, schedule, SQL statement and outbound host in `caramel_metrics`, aggregates only: never a path, a bind value or a message. New applications already require it; add it to an older one and run `frappe migrate` once, because its table comes with Cold Brew’s framework tables.

**config/application.cr**

```crystal
require "caramel"
require "caramel/crema/recorder"
```

**Terminal · on the server**

```bash
./bookshelf insights --since=24h
./bookshelf insights --kind=sql --since=1h
```

**Expect:** Each prints a table with `KEY COUNT ERR P50MS P95MS MAXMS TOTAL_S`, the 20 rows with the most total time, or `No aggregates in the last 24h. Is the recorder running?` when the window is empty. Without the recorder it prints `The Crema recorder is off. Add require "caramel/crema/recorder" to config/application.cr.` and exits 1. The console’s Insights page shows the same tables.

[Look up the table, retention and flush rules →](https://caramelize.dev/docs/0.15.0/crema/index.md)

## Send traces to a tracing backend {#c-crema-otlp}

Add `require "caramel/crema/otlp"` and set the standard OpenTelemetry variables; the application then exports each sampled request, job and schedule run, with a child span for every query and outbound call, as OTLP over HTTP with JSON bodies. Spans name routes and parameterized SQL, never paths, bind values, log text or error messages.

**Environment · where ./bookshelf serve runs**

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.com
OTEL_EXPORTER_OTLP_HEADERS=x-api-key=SECRET
OTEL_SERVICE_NAME=bookshelf
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1
```

**Expect:** The process prints nothing about the exporter; sampled traces appear in the backend under `bookshelf`. Without `OTEL_EXPORTER_OTLP_ENDPOINT` nothing is sent, and a protocol other than `http/json` logs a warning and leaves export off.

[Look up the seven variables and the sampling rules →](https://caramelize.dev/docs/0.15.0/crema/index.md)

[Read the tracing design ↗](https://github.com/caramelizedev/caramel/blob/v0.15.0/docs/decisions/0027-crema-tracing.md) · [Read the production access design ↗](https://github.com/caramelizedev/caramel/blob/v0.15.0/docs/decisions/0028-crema-production-access.md)

Stage 5 · Limits

## What does not compile {#c-crema-refusals}

Crema is on in every application and adds no word to the language, so it rarely stops a build.

| Condition | Outcome |
| --- | --- |
| A sink or exporter of your own whose `case … in` over `Caramel::Crema::SpanKind` lacks the `domain` kind | fails compilation |
| `insights` in an application without the recorder | exits 1 and says which line to add |
| `ops` with no running process | exits 1 and names the socket it looked for |

## Not covered yet {#c-crema-gaps}

- The collector and the exporter take OTLP over HTTP with JSON bodies only; protobuf is not supported.
- Errors on the ops socket live in memory only; a restart clears them.
- An error tracker is yours to connect through `Caramel::Crema.on_error`; Crema ships no client.

Prove it

## Check what your application reports {#c-crema-prove}

Add a route that raises, start `frappe dev`, then watch the failure reach each surface and no log line. This is the sequence Caramel’s own `scripts/check crema` runs against a fixture application in production mode.

**app/actions/probes/show.cr**

```crystal
module App::Probes
  struct Show < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      raise "probe: do-not-log"
    end
  end
end
```

**config/routes.cr · inside Caramel::Router.draw**

```crystal
    get "/probe", App::Probes::Show
```

**Terminal · inside your application, in a second terminal while frappe dev runs**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://bookshelf.caramel/probe
frappe errors --agent
frappe trace last-error --md
```

**Expect:** `curl` prints `500`. `frappe errors --agent` prints one `ERR RUNTIME:500` block naming `GET /probe` and exits 1. `frappe trace last-error --md` prints the trace with a `## Backtrace` section that names `app/actions/probes/show.cr`.

**Terminal · on the server, after a request to /probe**

```bash
./bookshelf ops status
./bookshelf ops errors
./bookshelf ops metrics
```

**Passing:** `ops status` starts with `App `. `ops errors` lists one row whose `CLASS` is `Exception` and whose `SOURCE` is `GET /probe`; `ops error FINGERPRINT` with that row’s fingerprint prints `probe: do-not-log`. `ops metrics` includes `caramel_requests_total{method="GET",route="/probe",status="500"}`. No line the process logged holds `do-not-log`: the message is on the socket and nowhere else.

[← Build a box office](https://caramelize.dev/docs/0.15.0/box-office/index.md) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.15.0/testing-html/index.md)

Caramel 0.15.0 · https://caramelize.dev/docs/0.15.0/observability/
