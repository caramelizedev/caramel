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

## Reasons

- `pg_stat_statements` answers "which statement is slow" with the cost the database
  measured, and `auto_explain` writes the plan of a slow one to the PostgreSQL log with
  no bind values, as `ecto_psql_extras` and Django Debug Toolbar users reach for.
- The statement tags Crema adds (ADR 0027) make those statistics attributable.
- Research: [observability](https://github.com/caramelizedev/caramel-notes/blob/main/research/observability.md).
