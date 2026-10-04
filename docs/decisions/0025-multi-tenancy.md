# ADR 0025: Opt-in multi-tenancy

Date: 2026-10-03

Status: accepted.

## Context

An application that serves several organizations must keep each one's rows apart. It
must be able to opt in, pay nothing when it does not, and plug tenancy in and out again.

## Decision

1. **Core hooks with identity bodies.** `Application#handle` routes through `tenanted`,
   which only yields; the generic 500 response is `failure`. `Caramel.tenant_path(path,
   of:)`, `Caramel::Cache.scoped` and `Caramel::ColdBrew.carry`, `carried` and `channel`
   return their input. Resource path helpers and the i18n locale switch pass through
   `tenant_path`. A job `param caramel_tenant` is a compile error.
2. **`require "caramel/tenancy"` is the only way in.** It redefines the hooks, and its
   `macro finished` guard refuses a program without a tenant block. The documented API is
   `Caramel::Tenancy.with`, `without`, `each`, `current` and `current?`; every other
   method is `# :nodoc:`.
3. **The first path segment names the tenant.**
   - `Caramel::Router.draw` takes one `tenant App::Account, by: :slug do … end` block;
     `by:` names a String field. Its routes match in a tree of their own, and `routes`
     lists them under `/:tenant`. Once a block exists, a central route other than `/`
     may not start with a parameter, and a tenant route may not start with a central
     route's first segment.
   - `Application#tenanted` reads a first segment that is a lowercase DNS label, not a
     central route's first segment and not a locale prefix, as a slug. It finds the
     tenant, removes the segment and routes in `Caramel::Tenancy.with`; an unknown slug
     is 404. Every other request routes with no tenant bound, so a reused fiber carries
     none in. A streamed body runs in the request's tenant. With locale prefixes, the
     tenant comes first: `/acme/fr/books`.
   - Actions and views have `tenant` and `tenant_path(path)`.
     `cs.validate_tenant_slug(:slug)` accepts only a slug the router would read.
4. **SugarORM's `tenant account : Account`** is a `belongs_to` that also scopes.
   - Its column is system-managed: never a changeset param, never NOT NULL-checked. It
     stays preloadable.
   - The table gets the unique index `index_<table>_on_account_id_and_id`, first among
     its indexes. A unique explicit index gains `account_id` and keeps its name, so it is
     unique per tenant. A `belongs_to` whose target is tenanted is the composite key
     `(author_id, account_id) → (id, account_id)`.
   - With a tenant bound, queries, `BelongsTo` and child preloads, updates and deletes
     add `"account_id" = $n`, and inserts stamp it. With none bound, a tenanted
     statement raises `SugarORM::Tenancy::Missing`, unless it runs inside `without`; an
     insert raises even there. Raw `SugarORM.sql` is not scoped.
   - Compile errors refuse a `tenant` without the require, a second `tenant`, a target
     that is not a schema or is tenanted, and a target other than the routes' model.
5. **Foreign keys span several columns.** `SugarORM::Catalog::ForeignKey` holds `columns`
   and `references_columns`, and the schema document is version 2. The differ drops every
   changed or undeclared key before any other statement, adds a composite key on a new
   table's own rows after that table's indexes, and halts a key that would wait on a
   unique index it only builds CONCURRENTLY; the halt prints the index to build first.
6. **Work outside a request.** A job enqueued in a tenant carries its id and runs in it; a
   job whose tenant is gone fails with `Caramel::Tenancy::Gone`. A job enqueued with no
   tenant runs with none. A `spawn`ed fiber starts with none. While a tenant is bound,
   cache keys and PubSub channels get the prefix `t<id>:`, and a prefixed channel stays
   within 63 characters.
7. **Frappé.** `frappe make tenancy MODEL` writes the tenant's schema, changeset,
   migration, sign-up page at `/PLURAL/new` and home at `/SLUG`, and adds the require,
   the tenant block, the path helpers and the `tenant_session` spec helper. In a
   multi-tenant application `frappe make resource` writes resources that belong to the
   tenant, and `--central` writes one every tenant shares, the same as a plain
   application's.
8. **Membership is the application's.** Whether a user may act in `acme` is its ingress
   check, such as `ingress authenticate: :member?`.

### Plugging in on existing data

1. Adding `tenant` to a populated table halts at "NOT NULL column without a default".
2. Write a migration by hand that adds the nullable column, backfills it and sets NOT
   NULL.
3. In a second migration, build the index: `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS
   "index_<t>_on_<col>_and_id" ON "<t>" ("<col>", "id")`. When another tenanted table's
   key references the table, the differ halts until the index exists and prints this SQL.
4. Run `frappe db diff` for the keys.

### Plugging out

1. Make every value of a per-tenant unique index unique across tenants: the differ
   rebuilds those indexes without the tenant column.
2. Remove the `tenant` lines and record `drop_column :account_id`.
3. Remove the require and the tenant block together, moving the block's routes out.
   Either one alone is a compile error.
4. Run `frappe db diff`.

## Reasons

- One require replaces identity hooks, so a plain application compiles none of the
  tenancy code; `scripts/check tenancy` proves it on the binary, as ADR 0024 does for i18n.
- Scoping fails closed. Crystal applications today scope with an explicit `where`, and
  one forgotten call leaks another tenant's rows; Ecto's `prepare_query`, Ash and
  activerecord-tenanted raise instead.
- Composite keys let PostgreSQL refuse a reference to another tenant's row, even from raw
  SQL, and the `(tenant, id)` index serves scoped reads.
- The tenant is bound per fiber and restored, as `Log.with_context` is, because
  HTTP::Server serves keep-alive requests on one fiber.
- A path prefix needs no DNS or certificates in development, and the slug is a DNS label,
  so subdomains can follow without changing application code.
- The survey behind these choices is
  [research/multi-tenancy.md](https://github.com/caramelizedev/caramel-notes/blob/main/research/multi-tenancy.md)
  in caramel-notes.

Rejected:

- **Subdomains now.** They need wildcard DNS and certificates before the first page works.
- **A schema per tenant.** SugarORM checks out a pooled connection per statement and caches
  prepared statements; introspection, migrations, Corretto, Latte and Cold Brew all assume
  one schema; and signing up would run DDL inside a request.
- **A database per tenant.** It multiplies pools, migrations and backups.
- **Row-level security now.** Owners bypass it without FORCE, and the setting must be bound
  per transaction, since crystal-db sets a connection up only when it opens one. It can be
  added later as a second layer.
- **Explicit scope arguments,** as in Phoenix, or `where(org_id: …)`. Both fail open when
  one call forgets.
- **`tenant: true` on path helpers,** and **a separate configuration declaration.** The
  router's tenant block already names the model, the slug and the tenant routes.
- **Deferred:** host-based identification, a per-tenant `Cache.clear`, and row-level
  security.
