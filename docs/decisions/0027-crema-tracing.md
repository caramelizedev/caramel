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
   Latte share. Nil fields are omitted. Production detail omits the request path, bind
   values, source locations, messages and backtraces.
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
