# ADR 0028: Crema's production access: the ops socket, console, recorder and exporter

Date: 2026-10-03

Status: accepted.

## Context

A production incident needs the running process's own view: what is in flight, which
errors repeat, which statements are slow, and what one person's request did. The
answer must not widen the public attack surface, must not put exception messages or
request paths in a log or a table, and must cost an application that does not want it
nothing.

## Decision

1. **The ops socket is the only door.** `serve` binds an owner-only Unix socket (mode
   0600, in a directory its owner alone can reach) inside the running binary; `work`
   binds one only when `CARAMEL_OPS_SOCKET` names a path. `CARAMEL_OPS_SOCKET=off`
   disables it. The default path is the application socket's, with `.ops.sock` for
   `.sock`. A socket whose directory is not private is not bound; the application keeps
   serving. A live socket is never replaced; a dead one is.
2. **Guards.** A request whose `Host` is not `ops`, `localhost`, `127.0.0.1` or `[::1]`
   (with or without a port) answers 421, which stops DNS rebinding. A write with an
   `Origin` header answers 403. JSON errors read
   `{"version":1,"error":{"code","message"}}`.
3. **The API, version 1.** `GET /v1/status`, `/v1/requests`, `/v1/fibers`, `/v1/metrics`
   (Prometheus text), `/v1/tail` (server-sent events, filtered by `errors`, `slow` and
   `logs`), `/v1/errors`, `/v1/errors/<fingerprint>`, `/v1/traces` and
   `/v1/traces/<ref>`, and `POST /v1/debug-tokens`. `/v1/errors/<fingerprint>` is the
   only answer that carries an exception's redacted message and backtrace.
4. **Rings, in memory.** The error ring keeps the newest report of each of at most 500
   fingerprints with its count. The trace ring keeps the newest 200 traces that failed,
   ran slow or carried a debug token, with their spans. Both start empty and are lost on
   restart.
5. **Prometheus names.** `caramel_requests_total`, `caramel_request_duration_seconds`,
   `caramel_jobs_total`, `caramel_job_duration_seconds`, `caramel_job_queue_lag_seconds`,
   `caramel_schedules_total`, `caramel_errors_total`, `caramel_inflight`,
   `caramel_db_pool_connections`, `caramel_db_pool_max`, the `caramel_gc_*` family,
   `caramel_fibers`, `caramel_crema_dropped_total`, `caramel_build_info` and
   `caramel_process_start_time_seconds`. Labels are route templates, class names and
   statuses; an unmatched route is `(none)`.
6. **Debug tokens.** `"<expires>.<hmac>"`, signed with a key derived from the
   application's secret, valid for at most two hours (15 minutes by default). Sent as
   `X-Caramel-Debug` or the `__Host-caramel_debug` cookie, it makes one request a debug
   trace: recorded, answered with `X-Caramel-Trace`, kept in the trace ring and passed
   to the jobs it enqueues.
7. **The console** is read-only HTML on the same socket, reached with `ssh -L`. Its pages
   load only their own stylesheet and script under a strict content security policy:
   overview, in flight, live tail, jobs, database, errors, traces and insights.
8. **Commands.** `APP ops status|requests|fibers|metrics|tail|errors|error|traces|trace|
   debug-token|console`, `APP jobs [stats|failed|show ID|retry ID|--class=NAME]` and
   `APP db diagnose` (`frappe db diagnose` runs it). `jobs` and `db diagnose` need no
   running application. `jobs show` is the one place a job's stored error is read, and it
   prints to the operator's terminal only. Registered commands extend `usage`.

## Reasons

- A Unix socket in the binary reaches the live fibers, pools and rings, which no sidecar
  can, and adds nothing to the public listener; Phoenix's remote shell and Go's pprof
  taught the same lesson, and the Host and Origin guards follow Tidewave's.
- A fixed command set replaces evaluating code, which Crystal cannot do at runtime.
- Bounded, expiring probes follow `recon_trace`: every token has a time limit and every
  ring a size.
- Rejected: error messages, backtraces or traces in PostgreSQL (the database keeps
  aggregates only); a web console on the public listener; an MCP daemon (principle 6).
- Deferred: CPU profiling and `-Dtracing` builds.
- Research: [observability](https://github.com/caramelizedev/caramel-notes/blob/main/research/observability.md).
