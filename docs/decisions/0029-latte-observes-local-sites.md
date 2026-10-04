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
   `auto_explain.log_min_duration = '250ms'`, `auto_explain.log_analyze = off`,
   `auto_explain.log_format = text`, `auto_explain.log_parameter_max_length = 0`). A
   cluster that lacks the preload restarts once through the ordinary start path.
2. **Statistics live in the `caramel_stats` schema** of each site's development database
   only. The extension is created there, the development migration and runtime roles
   may use the schema, and the runtime role is granted `pg_read_all_stats`. The spec
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

## Reasons

- `pg_stat_statements` answers "which statement is slow" with the cost the database
  measured, and `auto_explain` writes the plan of a slow one to the PostgreSQL log with
  no bind values, as `ecto_psql_extras` and Django Debug Toolbar users reach for.
- The statement tags Crema adds (ADR 0027) make those statistics attributable.
- Research: [observability](https://github.com/caramelizedev/caramel-notes/blob/main/research/observability.md).
