# ADR 0025: Opt-in multi-tenancy

Date: 2026-10-03

Status: accepted.

## Context

- The owner wants multi-tenancy that applications opt into. It must be off by default and free when unused. It must read plainly and stay out of the way, and pragmatism wins any tie. It must fit the manifesto (`docs/rfc.md` §1), and it must be simple to plug in and out.
- The owner fixed these choices:
  - **Identification:** the first path segment, as in `/acme/books`. Subdomains can follow later without changing application code.
  - **Storage:** shared tables with a tenant column.
  - **Enforcement:** SugarORM scoping that fails closed, plus composite foreign keys. Row-level security is deferred.
  - **Deliverables:** this ADR, a research note (`docs/research/multi-tenancy.md`), the runtime and the Frappé generators.
- The precedent is ADR 0024: `require "caramel/i18n"` replaces core hooks whose default bodies do nothing.
- Research into Crystal and other ecosystems gave these lessons (sources in the research note):

  |Lesson|Evidence|
  |---|---|
  |No Crystal shard does tenancy|Shardbox, shards.info and awesome-crystal list none. Forum topic 6733 got "extend current-user" and "database per tenant".|
  |Explicit `where(org_id: …)` fails open|spider-gazelle's template and kemalcr-starter scope by hand. PlaceOS patched an id lookup that "is not authority scoped".|
  |Scoping must fail closed|Ecto's `prepare_query` raises unless told to skip. Ash raises without a tenant. activerecord-tenanted has `NoTenantError`. stancl/tenancy and acts_as_tenant fail open by default.|
  |Composite foreign keys keep references inside a tenant|Ecto's `references(:posts, with: [org_id: :org_id])`.|
  |The tenant is bound per fiber and restored|Rails `CurrentAttributes.with`, Crystal's `Log.with_context`, Athena's per-request reset, Avram's fiber cache bug.|
  |Jobs, cache and PubSub carry the tenant|stancl/tenancy's queue payload and bootstrappers, spatie's `TenantAware` jobs, Fizzy's job capture, Phoenix's scoped topics.|
  |The tenant is a parent route|Ember's nested dynamic segment, Phoenix's `route_prefix`, Fizzy's `/{account_id}` in SCRIPT_NAME.|
  |Shared tables scale; schemas do not|Citus: schemas suit 1–10k tenants, rows 100 to over 1M. Every backend caches every schema's catalog.|

## Decision

1. **SugarORM foreign keys span several columns** (core, independent of tenancy).
   - `SugarORM::Catalog::ForeignKey` holds `columns` and `references_columns` arrays. This is a clean cutover with no aliases.
   - The catalog JSON is version 2. Version 1 is refused with "unsupported schema document version". The application binary and Frappé always come from the same release.
   - Introspection reads each key's columns in order. DDL renders `FOREIGN KEY ("a", "b") REFERENCES "t" ("x", "y")`.
   - The differ drops foreign keys before everything else, because a composite key depends on the referenced table's unique index.
   - A composite self-reference is added after its table's indexes, never inline.
   - A key that would wait on a unique index this diff builds CONCURRENTLY halts, and the halt prints the index to build first.
2. **Core identity hooks** change nothing for plain applications.
   - `Application#handle` routes through `tenanted`, which only yields. The generic 500 response moves into `failure`.
   - `Caramel.tenant_path(path, of:)` returns its path. Resource path helpers and the i18n locale switch pass through it.
   - `Caramel::ColdBrew.carry`, `carried` and `channel` are identities that the queue and PubSub call.
   - `Caramel::Cache.scoped(key)` returns its key; `write`, `read` and `delete` use it.
   - A job `param caramel_tenant` is a compile error, because the name is reserved.
3. **The router takes one `tenant App::Account, by: :slug do … end` block.**
   - Its routes live under `/:tenant`, in a second routing tree.
   - It needs `require "caramel/tenancy"`, and a router takes one such block.
   - Once a block exists, a central route other than `/` may not start with a parameter. A tenant route may not start with a central route's first segment.
   - The router calls `Caramel::Tenancy.declare` with the model, the slug field and the central first segments.
   - `frappe routes` prints tenant routes as `/:tenant/books`.
4. **SugarORM's `tenant account : Account` statement** is a belongs_to that also scopes.
   - Its column `account_id` is a system column: never a changeset param, never NOT NULL-checked. It stays preloadable.
   - Each tenanted table gets the unique index `index_<table>_on_account_id_and_id`. It serves scoped reads and is the target of composite keys.
   - A unique explicit index becomes unique per tenant: its columns gain `account_id`, and its name stays.
   - A `belongs_to` whose target is also tenanted gets a composite key `(author_id, account_id)`.
   - Queries, `BelongsTo` and child preloads, updates and deletes add `"account_id" = $n`. Inserts stamp the bound tenant. Plain schemas compile to today's code.
   - A tenanted statement with no tenant bound, outside `without`, raises `SugarORM::Tenancy::Missing`. An insert raises even inside `without`.
   - Compile errors refuse a missing require, a second `tenant`, a target that is not a schema, a tenanted target and a target the routes do not declare.
5. **`require "caramel/tenancy"` is the only way in.**
   - `Caramel::Tenancy.with`, `without`, `each`, `current` and `current?` are the documented API. Every other method is `# :nodoc:`.
   - Actions and views get `tenant` and `tenant_path(path)`.
   - `Application#tenanted` finds the tenant the first segment names, strips the segment and routes inside `with`. An unknown slug answers 404. A central request binds no tenant, so a reused fiber carries none in.
   - Streamed bodies run in the request's tenant.
   - Jobs enqueued in a tenant run in it. A job whose tenant was deleted fails with `Caramel::Tenancy::Gone`.
   - Cache keys and PubSub channels get the prefix `t<id>:` while a tenant is bound.
   - `cs.validate_tenant_slug(:slug)` accepts a lowercase DNS label that no central route or locale prefix uses.
   - A `macro finished` guard refuses the require without a tenant block.
6. **Frappé:**
   - `frappe make tenancy MODEL` writes the tenant's schema, migration, changeset, sign-up page at `/PLURAL/new` and home at `/SLUG`. It adds the require, the tenant block, the paths line and the `tenant_session` spec helper.
   - In a multi-tenant application, `frappe make resource` writes resources that belong to the tenant. `--central` writes one every tenant shares, byte-identical to a plain application's.

## Reasons

- Hooks with identity bodies let one require replace them. A plain application compiles none of the tenancy code, and the check proves it.
- Scoping in SugarORM fails closed. A forgotten filter is a raised error, not a leak.
- Composite keys let PostgreSQL refuse a cross-tenant reference, even from raw SQL.
- Path identification needs no DNS or TLS setup in development, and `by:` leaves room for hosts later.

Alternatives the owner rejected:

- **Subdomains now.** They need wildcard DNS and certificates before the first page works. The slug is already a DNS label, so they can come later.
- **Schema per tenant.** It fights SugarORM's pool and prepared statements, introspection, migrations, Corretto, Latte and Cold Brew. The research note lists each cost.
- **Database per tenant.** It multiplies pools, migrations and backups, and it costs more than schemas.
- **Row-level security now.** Owners bypass it without FORCE, and the setting must be bound per transaction. It can be added later as a second layer.
- **Explicit scope arguments,** as in Phoenix, or Crystal's usual `where(org_id: …)`. Both fail open when one call forgets, as PlaceOS's patched lookup shows.
- **`tenant: true` on path helpers.** It duplicated what the router already knows.
- **A separate config-level declaration.** The router block already names the model and the slug.

### Plugging in on existing data

1. Adding `tenant` to a populated table halts at "NOT NULL column without a default".
2. Write a migration by hand that adds the nullable column, backfills it and sets NOT NULL.
3. In a second migration, build the index: `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_<t>_on_<col>_and_id" ON "<t>" ("<col>", "id")`. When another tenanted table's key references the table, the differ halts until the index exists, and its halt prints this exact SQL.
4. Run `frappe db diff` for the keys.

### Plugging out

1. Make every value of a per-tenant unique index unique across tenants. The differ rebuilds those indexes without the tenant column, and the build fails on a value two tenants share.
2. Remove the `tenant` lines and record `drop_column :account_id`.
3. Remove the require and the tenant block together, moving the block's routes out of it. Either one alone is a compile error: the require's guard asks for a tenant block, and a tenant block or `tenant` line asks for the require.
4. Run `frappe db diff`.

### Fail-open edges

- A hand-written model that forgets `tenant` is not scoped.
- Raw `SugarORM.sql` is not scoped. It is the explicit escape hatch.
- A `spawn`ed fiber starts without a tenant. Wrap its work in `Caramel::Tenancy.with`, as jobs are wrapped. Without it, its tenanted statements still raise, but its cache keys and PubSub channels get no prefix, and the jobs it enqueues carry no tenant.

Not part of this decision, each a separate feature:

- subdomain or host resolution (`tenant App::Account, by: :slug, from: :host do`);
- row-level security, with `set_config('app.tenant', …, true)` per transaction, since crystal-db's `setup_connection` runs only when a connection is created;
- a per-tenant `Cache.clear`;
- membership and authorization. Whether a user may act in `acme` is the application's ingress check, such as `ingress authenticate: :member?`.

## Verification

- `scripts/crystal spec spec/sugar_orm` and `scripts/check schema-diff` cover composite keys, key drop order, the composite self-reference, the online-index halt and the version 2 catalog.
- `scripts/check tenancy`:
  - type-checks a valid fixture and one fixture per compile error in `spec/fixtures/tenancy`, and asserts each problem text and file;
  - builds the same application without and with `caramel/tenancy`, and fails with "tenancy code must be absent from an application that does not require caramel/tenancy" unless only the second binary holds "is tenanted, but no tenant is bound". Both must answer `200` for `/` and `404` for `/Nope`.
- `scripts/check integration` round-trips a composite key through introspection, then runs `spec/tenancy` on PostgreSQL. It covers scoping, stamping, per-tenant uniqueness, cross-tenant foreign-key violations, requests, fiber reuse, jobs, cache, PubSub, `each`, `validate_tenant_slug` and the routes listing. Those specs replace framework hooks, so they are not part of the main spec run.
- `scripts/check route-compilation` and `scripts/check orm-compilation` keep their fixtures passing.
- `spec/frappe/tenancy_generator_spec.cr` and `spec/frappe/resource_generator_spec.cr` cover `frappe make tenancy`, tenant and `--central` resources, and every refusal.
- `scripts/check frappe-project` runs `frappe make tenancy Account`, a tenant resource and a central one in a generated application. It asserts the routes, that the migrations equal `frappe db diff`, and that Corretto passes 9 spec files on 2 workers.

## Implementation

- SugarORM keys: `src/sugar_orm/catalog.cr`, `introspection.cr`, `ddl.cr`, `differ.cr` and `schema.cr`.
- Hooks: `src/caramel/application.cr` (`tenanted`, `failure`), `src/caramel/http/paths.cr`, `src/caramel/i18n/runtime.cr`, `src/caramel/cold_brew.cr`, `src/caramel/cold_brew/queue.cr`, `src/caramel/cold_brew/job.cr` and `src/caramel/cache.cr`.
- Router: `src/caramel/http/router.cr` and `src/caramel/command_line.cr` (`routes`).
- SugarORM scoping: `src/sugar_orm/tenancy.cr`, `schema.cr`, `query.cr`, `associations.cr`, `changeset.cr` and `repo.cr`.
- `caramel/tenancy`: `src/caramel/tenancy.cr`, `src/caramel/tenancy/declaration.cr`, `runtime.cr` and `tenanted.cr`.
- Frappé: `src/frappe/tenancy_generator.cr`, `src/frappe/resource_generator.cr`, `src/frappe/commands.cr`, `src/frappe/cli.cr`, `templates/tenancy` and `templates/resource`.
- Checks: `scripts/checks/tenancy.cr`, `spec/fixtures/tenancy`, `spec/tenancy`, `scripts/checks/integration.cr` and `scripts/checks/frappe_project.cr`.
