# ADR 0029: Latte observes local sites

Date: 2026-10-03

Status: accepted.

## Context

Crema's development tools stop at one application. A developer also wants the
database's own view of the queries it runs, a site's HTTP traffic as the proxy saw it,
and one trace across several local sites and services, from the machine's menu bar. Latte
owns the PostgreSQL cluster, the HTTPS proxy and the menu bar app, so it is where those
belong.

## Decision

1. **The managed cluster collects statement statistics.** Latte preloads
   `pg_stat_statements` and `auto_explain` (`shared_preload_libraries =
   'pg_stat_statements,auto_explain'`, `pg_stat_statements.track = top`,
   `pg_stat_statements.track_utility = off`, `auto_explain.log_min_duration = '250ms'`,
   `auto_explain.log_analyze = off`, `auto_explain.log_format = text`,
   `auto_explain.log_parameter_max_length = 0`). Utility statements are not tracked, so
   no `ALTER ROLE … PASSWORD` literal reaches the statistics. A cluster that lacks the
   preload or the setting restarts once through the ordinary start path.
2. **Statistics live in the `caramel_stats` schema** of each site's development database
   only. The extension is created there, the development migration and runtime roles
   may use the schema, and no role is granted `pg_read_all_stats`, so a role reads the
   statement text of its own statements only. The spec
   database has none. Keeping the views out of `public` keeps them out of SugarORM's
   introspection and Corretto's catalog fingerprint.
3. **Dumps leave it out.** `frappe db dump` excludes the schema and the extension, because
   `restore` runs as the migration role, which cannot create an extension.
   `frappe db diagnose` reads the statistics when the extension is present.
4. **Control API version 2 carries each site's errors.** Latte serves `/v1/…` and `/v2/…`
   through the same routes, and every body names the version asked for. A version 2 site
   adds `errors`, the number of errors its development application reported since
   `frappe dev` started, and `last_error`: `{fingerprint, error_class, location, at}`
   or null, with a location of at most 200 characters and never a message. The
   development gateway reports both on its status endpoint; a gateway that predates
   them reads as zero errors. A version 1 site is unchanged. Frappé, Corretto and
   Latte.app ask for version 2; a Latte that serves only version 1 is refused with
   `latte stop` as the remedy.
5. **Latte.app raises alerts.** A site's menu title shows its error count, its submenu the
   newest error, and an Open inspector item opens `/__caramel/dev/inspector`. A build
   that turns to `build-error`, or an error fingerprint not yet seen for that site in this
   run, adds to a count beside the status item and, when macOS allows, posts a
   notification that opens the inspector. The first snapshot after launch seeds what is
   known and alerts nothing; opening the menu clears the count.
6. **Each site has its own Caddy access log.** Latte's proxy configuration holds one logger
   per registered site, `site_<id>`, that writes JSON to `<logs>/sites/<id>/access.log`
   with mode 0600, rolled at one megabyte with one previous file. The HTTPS server maps
   each domain to its logger and skips unmapped hosts, and the default logger excludes
   `http.log.access`, so `proxy.log` carries no access lines. The directory is the one
   Frappé keeps `app.log`, `compiler.log` and `events.jsonl` in; `frappe logs access`
   prints the file. Caddy redacts `Cookie` and `Authorization`.
7. **Latte collects local traces.** The daemon listens on `127.0.0.1:4318`, the OTLP/HTTP
   port, for `POST /v1/traces` with a JSON body of at most 4 MiB. It keeps the newest 2000
   traces with at most 200 spans each, in memory, and refuses protobuf with 415. A busy
   port leaves the collector `unavailable` and the daemon running. It serves no reads:
   control API 2 lists traces (`GET /v2/traces?limit=N`), returns one (`GET
   /v2/traces/<id>`) and reports the collector in `/v2/status`. Version 1 has none of it.
   `frappe dev` forwards each trace of the application to the collector as
   OTLP JSON under the project's name, and the inspector and `frappe trace --md` add an
   "Across services" section when another service joined the trace. The services stay
   out of the three-service readiness states.

## Reasons

- `pg_stat_statements` answers "which statement is slow" with the cost the database
  measured, and `auto_explain` writes the text and plan of a statement of 250 ms or more
  to `postgres.log`; application statements carry placeholders, so no bind values reach
  it. Utility statements are not tracked, because `ALTER ROLE … PASSWORD` carries a
  literal, and a role sees only its own statements' text.
- The statement tags Crema adds (ADR 0027) make those statistics attributable.
- Local OTLP SDKs speak HTTP over TCP, so the collector is an exception to the Unix-socket
  rule. Any local process may write, as with any OpenTelemetry collector; only the owner
  can read, over the control socket. Traces hold span names and attributes the exporter
  chose, never a Caramel secret (ADR 0028).
- Research: [observability](https://github.com/caramelizedev/caramel-notes/blob/main/research/observability.md).
