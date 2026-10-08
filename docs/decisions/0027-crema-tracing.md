# ADR 0027: Crema traces every request, job and schedule run

Date: 2026-10-03

Status: accepted.

## Context

A request that fails or slows down must be traceable from the log line to its queries,
its background jobs and the outbound calls it made, in development and in production.
Frameworks that solved this (Rails, Phoenix, Laravel) put one event at the centre and
let sinks decide what to keep. Caramel needs the same without a second runtime, without
secrets in logs and without a diagnostic that costs a production binary anything.

## Decision

1. **Crema is `Caramel::Crema`.** The core, `src/caramel/crema.cr`, compiles into every
   application and requires no database or Cold Brew code. Opt-in parts live under
   `caramel/crema/…` and register through `Crema.on_start`, `Crema.command` and
   `Crema.console_page`; they redefine no method.
2. **One trace per unit of work.** `Crema.request` traces each routed request. A trace
   has a request id, a 32-hex trace id and a 16-hex span id, binds to its fiber and to
   `Log.context`, and goes to every sink when it finishes. Static files and the 400 and
   421 refusals are not traced.
3. **Identifiers.**
   - The request id is the inbound `X-Request-ID` when it matches
     `/\A[A-Za-z0-9._:\-]{8,128}\z/`, else a UUID. It is returned as `X-Request-ID`.
   - A valid W3C `traceparent` (version `00`, lowercase hex, no all-zero id) supplies the
     trace id and `parent_id`; its sampled bit is kept as `parent_sampled`.
4. **Wire format version 1.** `TraceEvent`, `SpanEvent`, `RepeatEvent`, `ErrorEvent` and
   `BuildEvent` in `crema/event.cr` are the one definition the application, Frappé and
   `ErrorEvent.location`, a project-relative `file:line:column` of the fingerprint frame,
   stays in production. Production detail omits request paths, bind values, SQL source
   lines, messages and backtraces.
5. **Canonical log lines.** The `crema` source writes one entry per finished trace
   (message `request`, `job` or `schedule`) and one per error report (message `error`).
   `CARAMEL_LOG_FORMAT` chooses `json` or `text`; the default is text in development
   and test, JSON elsewhere. `LOG_LEVEL` sets the level.
6. **Errors go through `Crema.report`.** It builds an `ErrorReport`: class, redacted
   message and backtrace, a 12-hex fingerprint of the class and the first application
   frame's file and method (never line, column or message), `handled`, source and ids. It
   never raises; a sink that raises is logged. `Crema.on_error` hooks receive reports.
7. **The secrets rule.** Logs, tail events, metrics labels and every table Crema writes
   never carry exception messages, SQL bind values, request paths or bodies. Redacted
   messages and backtraces exist only in the in-memory error ring and in
   development-only surfaces. `Crema::Redact` removes secret-looking environment values,
   database URLs and `name=value` credentials.
8. **Sinks.** A `Sink` says whether it wants spans (`records?`, asked once per trace) and
   receives `finished` and `reported` on the reporting fiber without blocking. The log,
   metric and tail sinks are built in. The thresholds `Crema.slow_request` (1 s),
   `Crema.slow_job` (5 s) and `Crema.slow_query` (100 ms) flag slow work.
9. **Route labels.** The matched route's template, such as `/books/:id` or
   `/:tenant/books`, names the trace (`GET /books/:id`); an unmatched request is
   `GET (none)`.
10. **Runtime.** `Crema.start` is called by `serve` and `work` with the role, database
    pools, Cold Brew service and application; `Runtime#stop` runs the stoppers that
    start blocks returned, newest first.
11. **SugarORM stays independent.** `SugarORM::Repo` yields each statement through two
    hooks, `observe` and `observe_checkout`, that only yield. `caramel/crema/sql`
    redefines them: it times the statement as an `sql` span, counts slow statements and,
    when the trace records, statements repeated five or more times. The span's name
    is the verb and first table (`SELECT books`); its detail is the parameterized SQL,
    never a bind value.
12. **Statements name their code.** Inside a trace every statement starts with
    `/*action='App%3A%3ABooks%3A%3AShow'*/ ` (`job='…'`, `schedule='…'` for background
    work), so `pg_stat_activity` and PostgreSQL's logs name the code that ran it. The tag
    is prepended, so a trailing comment or `;` cannot swallow it, and holds nothing that
    varies per request, so prepared statements stay reusable.
13. **Work carries its trace.** `caramel_jobs.context` (jsonb, a framework migration) holds
    the enqueuing trace's `traceparent`, request id and, for a debug trace, `"debug":true`.
    The job's trace continues that trace; its `parent_id` is the enqueuing span. A schedule
    run starts a trace of its own. `Caramel::Outbound` times each call as an `http` span and
    sends `traceparent` unless the caller set one; cache reads count hits and misses; views
    are `view` spans and only the outermost counts in `view_ms`.
14. **Cold Brew reports through Crema.** A job's failure, a failing hook and the worker,
    maintenance and scheduler loops call `Crema.report`; the old per-component `error_type`
    log lines are gone. A fiber reports an exception once.
15. **`dump` is a development aid.** `dump value` prints the value and its location and adds
    a `dump` span in a development build with `CARAMEL_ENV=development`; elsewhere it
    returns the value untouched. Pools carry an `application_name` (`caramel-web`,
    `caramel-cold-brew`, `caramel-listen`) so every backend is attributable.
16. **JSON lines.** A data key equal to `ts`, `level`, `source` or `msg` (an error's
    `source`) is written with a `data_` prefix.
17. **Development surfaces are compiled out of production.** They need
    `-D caramel_development` and `CARAMEL_ENV=development`: the rich error page, the
    event sink, `Server-Timing` and a query's binds, their PostgreSQL literals and source line.
    A `nil` bind is recorded as a lone NUL character, shown as `NULL`. The error page adds
    an editor link per application frame, the source around the failing line, the
    request, the queries before the error, the causes and Copy as Markdown; a client
    that lists JSON first gets JSON.
18. **Editor links.** `CARAMEL_EDITOR` names `zed` (the default), `vscode`, `cursor`,
    `sublime`, `textmate`, `idea` or a template with `{path}`, `{line}` and `{column}`.
19. **`frappe dev` keeps the events.** It listens on a private socket
    (`CARAMEL_DEV_EVENTS`); the application's dev sink writes each finished trace and
    unattached error there as a JSON line. The newest 500 traces stay in memory and every
    line is appended to the site log's `events.jsonl`, which `frappe traces`,
    `frappe trace REF [--md]` and `frappe errors` read without a session. `frappe trace
    REF` also resolves the fingerprint of an error that happened outside a trace, and
    prints that error and its backtrace. `frappe errors` prints MRDP `RUNTIME` and
    `REPEATED_QUERY`, and leaves out what happened before the newest successful build.
20. **The inspector** is at `/__caramel/dev/inspector` on the development origin: requests,
    traces with a waterfall, errors by fingerprint and builds. A toolbar on each page
    links its route, time, queries and flags to the trace page's `#timeline`, `#queries`
    and `#error`, and **Copy for an agent** fetches `/__caramel/dev/trace.md?id=` (a hex
    id; session cookie and `X-Caramel-Dev` required). A query offers **Copy SQL** and
    **Copy with values**, which fills each `$n` from the literals recorded in development
    detail and leaves what it cannot fill. A query is a card: its statement with one clause
    per line (display only; a copy writes the statement as it ran) and each bind listed
    beside its `$n`. The toolbar, the inspector and the ops console
    follow the system's light or dark appearance, and a Theme button overrides it. The
    inspector and the console share one palette file; the toolbar keeps its own because
    it lives in a shadow root and never changes the page's `<html>`.
    Compile errors link to the editor, and Latte.app opens the inspector.

## Reasons

- One event with pluggable sinks keeps logs, metrics, the inspector and exports in
  agreement, as Rails' event reporter and Phoenix's telemetry do.
- A fingerprint without lines or messages keeps one defect in one group across deploys
  and keeps secrets out of grouping keys.
- Reusing the existing redaction and application-frame rules gives one classifier.
- Rejected: logging exception messages (dependency errors carry URLs and form values);
  storing errors or traces in PostgreSQL (the database keeps aggregates only, see
  ADR 0028).
- Research: [observability](https://github.com/caramelizedev/caramel-notes/blob/main/research/observability.md).
