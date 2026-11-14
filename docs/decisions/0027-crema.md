# ADR 0027: Crema traces every request, job and schedule run, keeps secrets out of what it writes, and opens production through an owner-only socket

Date: 2026-10-03

Status: accepted.

## Context

A request that fails or slows down must be traceable from its log line to its queries, its background jobs and its outbound calls, in development and in production. A production incident needs the running process's own view: what is in flight, which errors repeat, which statements are slow, and what one person's request did. Caramel needs both without a second runtime, without secrets in a log or a table, without a wider public attack surface, and at no cost to an application that does not want them.

## Decision

1. **Crema's core compiles into every application, and every other part is an opt-in require.** The core needs no database and no Cold Brew code.
2. **One trace per unit of work.** Each routed request, each claimed job and each schedule run is one trace. Static files are not traced.
3. **Inbound trace context is trusted by default, and one setting ignores it.**
4. **A trace is named by its route template, never by a path.** Metric labels are route templates, class names and statuses.
5. **One event, and sinks decide what to keep.** A finished trace and an error report go to every sink: the log line, the metrics, the development inspector and the exports. One wire format is shared by the application, Frappé, the ops socket and Latte.
6. **Every error goes through one report function, which never raises.** Its fingerprint covers the exception's class and the first application frame's file and method, never a line, a column or a message. Cold Brew reports through it too.
7. **The secrets rule.** Logs, tail events, metric labels and every table Crema writes never carry an exception message, a SQL bind value, a request path or a body. Redacted messages and backtraces exist only in memory and in development-only surfaces.
8. **SugarORM stays independent of Crema.** SugarORM yields each statement through hooks that only yield; Crema's SQL part redefines them.
9. **Statements name their code.** Inside a trace every statement starts with a comment naming the action, job or schedule. The tag is prepended and holds nothing that varies per request.
10. **Work carries its trace.** A job continues the trace that enqueued it, and outbound calls propagate the trace.
11. **A span kind names domain operations.** It carries no arguments and no ids. SweetTalk's use is in [ADR 0046](sweettalk/0046-transactions.md).
12. **Development surfaces are compiled out of production.** The rich error page, bind values, source lines and the event sink need a development build.
13. **The inspector is served by the development gateway to a signed-in browser only.** `frappe dev` keeps the events the application emits.
14. **The ops socket is the only door into a running process.** It is an owner-only Unix socket bound inside the running binary, and it serves the API, the metrics and a read-only console. Its directory is private even when the application socket admits a group ([ADR 0032](0032-production.md)); a socket that cannot be private is not bound, and the application keeps serving.
15. **Every ops request presents a key the process writes to a file at start.** A Host guard and an Origin guard apply as well.
16. **Production errors and traces live in bounded in-memory rings.** They are lost on restart, and the database keeps aggregates only. One error endpoint is the only answer that carries a redacted message and backtrace.
17. **A debug token traces one person's requests for a bounded time.** It is signed with a key derived from the application's secret, and the jobs a debug request enqueues are traced too.
18. **Production access is a fixed set of binary commands.** The job and database diagnostics need the database and no running application. A job's stored error is printed to the operator's terminal only.
19. **The recorder is opt-in and stores aggregates only.** A failed write changes nothing for the work it measured.
20. **The OTLP exporter is opt-in and sends nothing until an endpoint is set.** Exported spans name the route and the SQL, never a path, a bind value or a message. An exporter failure never reaches the work.

## Reasons

- One event with pluggable sinks keeps logs, metrics, the inspector and exports in agreement.
- A fingerprint without lines or messages keeps one defect in one group across deploys and keeps secrets out of grouping keys.
- With inbound trust off, a client can neither choose its trace nor force sampling.
- A statement tag makes `pg_stat_activity` and PostgreSQL's logs name the code that ran a statement. Prepended, no trailing comment or `;` swallows it; constant per action, prepared statements stay reusable.
- A domain span names the operation a trace ran, which its SQL alone does not. With no arguments or ids, production keeps it whole.
- A Unix socket in the binary reaches the live fibers, pools and rings, which no sidecar can, and adds nothing to the public listener.
- The key file is the boundary: a TCP forward discards socket permissions, but the file cannot be read from the operator's laptop. The Host guard stops DNS rebinding.
- A fixed command set replaces evaluating code, which Crystal cannot do at runtime.
- Probes are bounded and expiring: every token has a time limit and every ring a size.
- Rejected: logging exception messages. Dependency errors carry URLs and form values.
- Rejected: storing errors, messages, backtraces or traces in PostgreSQL.
- Rejected: a Unix-socket forward, because a browser cannot open one and a relay is a TCP port again.
- Rejected: a token for browsers only, because any local process can send the CLI's headers.
- Rejected: a web console on the public listener.
- Rejected: an MCP daemon. Agents get stateless command-line tools, not daemons.
- Deferred: CPU profiling and `-Dtracing` builds.
