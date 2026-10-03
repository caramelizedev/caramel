# Multi-tenancy research

This note gathers what ADR 0025 drew on. It covers the Crystal ecosystem, how
other frameworks scope tenants, and why Caramel does not use a schema per
tenant.

## Crystal ecosystem: no tenancy shard exists

- Shardbox finds nothing for
  [`tenant`](https://shardbox.org/search?q=tenant),
  [`tenancy`](https://shardbox.org/search?q=tenancy) or
  [`multitenant`](https://shardbox.org/search?q=multitenant).
- shards.info finds only an
  [unrelated CLI](https://shards.info/search?query=tenant).
- [awesome-crystal](https://raw.githubusercontent.com/veelenga/awesome-crystal/master/README.md)
  lists none.
- A [GitHub repository search](https://github.com/search?q=tenant+language%3Acrystal&type=repositories)
  finds only app templates.

## Crystal forum

- [Topic 6733](https://forum.crystal-lang.org/t/rubys-actsastenant-gem-equivalent-for-multi-tenancy-in-crystal/6733)
  asked for an ActsAsTenant equivalent. The two answers were "extend your
  framework's current-user notion" and "consider a database per tenant",
  citing DHH.
- [Topic 697](https://forum.crystal-lang.org/t/usage-of-kemals-add-context-storage-type/697)
  only stored a tenant in Kemal's `env`.

## How Crystal apps do it today: explicit `where`, which fails open

- [spider-gazelle/multi-tenancy-template](https://github.com/spider-gazelle/multi-tenancy-template)
  uses `Models::Resource.where(organization_id: current_org.id)`. The org
  lives in a controller ivar.
- [kemalcr-starter](https://raw.githubusercontent.com/kefyusuf/kemalcr-starter/master/docs/architecture/tenancy-model.md)
  keeps the org id in the request context. Scoping is "explicit in SQL".
- PlaceOS:
  - It resolves `Authority.find_by_domain(request.hostname)` and checks that
    the JWT's domain matches
    ([current-user.cr](https://raw.githubusercontent.com/PlaceOS/rest-api/master/src/placeos-rest-api/utilities/current-user.cr)).
  - It has paired scoped and unscoped finders, and
    `ensure_unique … scope: [:authority_id]`
    ([user.cr](https://raw.githubusercontent.com/PlaceOS/models/master/src/placeos-models/user.cr)).
  - A controller admits that an id lookup "is not authority scoped", and
    patches it to answer 404
    ([users.cr](https://raw.githubusercontent.com/PlaceOS/rest-api/master/src/placeos-rest-api/controllers/users.cr)).

Each of these scopes by hand. One forgotten `where` leaks another tenant's rows.

## Scope mechanisms in Crystal ORMs

- Avram has per-query-class `defaults`, which `reset_where` removes
  ([querying guide](https://luckyframework.org/guides/database/querying)).
- Lucky has
  [`require_subdomain`](https://luckyframework.org/guides/http-and-routing/routing-and-params#subdomains).
- Marten has a compile-time `default_scope` macro with `unscoped`
  ([queries](https://martenframework.com/docs/models-and-databases/queries),
  [querying.cr](https://raw.githubusercontent.com/martenframework/marten/main/src/marten/db/model/querying.cr)).
- Jennifer overrides `.all`
  ([model scopes](https://raw.githubusercontent.com/imdrasil/jennifer.cr/master/docs/model_scopes.md)).
- Granite has no default scope
  ([querying](https://raw.githubusercontent.com/amberframework/granite/master/docs/querying.md)).
- pg-orm has no default scope
  ([README](https://raw.githubusercontent.com/spider-gazelle/pg-orm/master/README.md)).

## Fiber state in Crystal

- `Log.context` is fiber-local, and `Log.with_context` restores it
  ([Log API](https://crystal-lang.org/api/latest/Log.html),
  [main.cr](https://raw.githubusercontent.com/crystal-lang/crystal/master/src/log/main.cr)).
- HTTP::Server handles keep-alive requests on one fiber, and wraps each in
  `Log.with_context`
  ([request_processor.cr](https://raw.githubusercontent.com/crystal-lang/crystal/master/src/http/server/request_processor.cr)).
- Athena resets its per-fiber container on every request
  ([athena.cr](https://raw.githubusercontent.com/athena-framework/athena/master/src/components/framework/src/athena.cr)).
- Avram's fiber query cache assumed one fiber per request
  ([avram#763](https://github.com/luckyframework/avram/pull/763)).
- crystal-db's `setup_connection` runs only when a connection is created
  ([database.cr](https://raw.githubusercontent.com/crystal-lang/crystal-db/master/src/db/database.cr)).

So a tenant bound to a fiber must be restored after each request, and a
per-connection setting cannot carry it.

## Other ecosystems

### Laravel: stancl/tenancy

- Middleware identifies the tenant by domain, subdomain, path or request data
  ([identification](https://tenancyforlaravel.com/docs/v3/tenant-identification)).
- In single-database mode, `BelongsToTenant` adds a global scope and stamps
  rows on create
  ([single-database tenancy](https://tenancyforlaravel.com/docs/v3/single-database-tenancy)).
  It fails open when no tenant is set
  ([TenantScope.php](https://raw.githubusercontent.com/archtechx/tenancy/3.x/src/Database/TenantScope.php)).
- The queue payload carries `tenant_id`, and bootstrappers scope the cache and
  the filesystem ([queues](https://tenancyforlaravel.com/docs/v3/queues)).

### Laravel: spatie/laravel-multitenancy

- It has `makeCurrent`, `execute(fn)`, `NeedsTenant` and `TenantAware` jobs.
- A known pitfall: a `PendingDispatch` lands in the wrong tenant.
- Source:
  [executing code for tenants and landlords](https://spatie.be/docs/laravel-multitenancy/v4/advanced-usage/executing-code-for-tenants-and-landlords).

### Ecto

- `prepare_query` adds the org filter, and raises unless `skip_org_id: true`.
- Composite keys use `references(:posts, with: [org_id: :org_id])`.
- Source:
  [multi-tenancy with foreign keys](https://hexdocs.pm/ecto/multi-tenancy-with-foreign-keys.html).
- Query prefixes get expensive as the number of tenants grows
  ([multi-tenancy with query prefixes](https://hexdocs.pm/ecto/multi-tenancy-with-query-prefixes.html)).

### Ash

- Attribute multitenancy filters reads, stamps creates and scopes identities
  to the tenant.
- It raises without a tenant, unless the resource is `global? true`.
- Source: [multitenancy](https://hexdocs.pm/ash/multitenancy.html).

### Phoenix 1.8

- An explicit `%Scope{}` argument, with scoped generators and PubSub topics.
- `route_prefix: "/orgs/:org"`.
- Source: [scopes](https://hexdocs.pm/phoenix/scopes.html).
- Generated tests check isolation between two scopes
  ([test_cases_scope.exs.eex](https://raw.githubusercontent.com/phoenixframework/phoenix/main/priv/templates/phx.gen.context/test_cases_scope.exs.eex)).

### Rails

- [`CurrentAttributes.with`](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)
  binds a value for a block.
- [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant) has
  `without_tenant`, `require_tenant` and job carry. It fails open by default.
- apartment's `search_path` leaks
  ([v4 connection model rationale](https://raw.githubusercontent.com/rails-on-services/apartment/main/docs/designs/v4-connection-model-rationale.md)).
- 37signals Fizzy puts `/{account_id}` in SCRIPT_NAME, and its jobs capture
  the account
  ([account_slug.rb](https://raw.githubusercontent.com/basecamp/fizzy/main/config/initializers/tenanting/account_slug.rb)).
- activerecord-tenanted raises `NoTenantError`
  ([GUIDE.md](https://raw.githubusercontent.com/basecamp/activerecord-tenanted/main/GUIDE.md)).

### Ember

- A parent route with a dynamic segment nests its child routes
  ([defining your routes](https://guides.emberjs.com/release/routing/defining-your-routes/)).
- `modelFor` reads the parent's model
  ([specifying a route's model](https://guides.emberjs.com/release/routing/specifying-a-routes-model/)).
- This is the shape of `tenant App::Account, by: :slug do`.

### PostgreSQL

- Table owners bypass row-level security without FORCE
  ([row security policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)).
- `set_config(…, true)` is transaction-local, and PgBouncer drops session
  `SET` ([PgBouncer features](https://www.pgbouncer.org/features.html)).
- Citus: schemas suit 1–10k tenants, and rows suit 100 to over 1M. Every
  backend caches every schema's catalog
  ([Citus 12](https://www.citusdata.com/blog/2023/07/18/citus-12-schema-based-sharding-for-postgres/)).

## Why schema per tenant does not fit Caramel

- SugarORM checks out a pooled connection per unbound statement, and has no
  checkout hook (`src/sugar_orm/repo.cr:118-126`). A `search_path` could not
  follow the request. The pool defaults to 4 connections, at most 32
  (`src/caramel/database.cr:37-38`).
- Prepared statements are cached (`src/caramel/database.cr:129-130`).
  PostgreSQL re-parses them whenever `search_path` changes.
- Introspection reads `current_schema()` only.
- `caramel_migrations` is unqualified (`src/sugar_orm/migration.cr:104-174`).
- Corretto's fingerprint hard-codes `public` (`src/caramel/corretto/worker.cr:32-49`).
- Latte grants privileges only in `public` (`src/latte/postgres.cr:1153-1161`).
- Cold Brew's tables must stay global.
- Migrations would run once per tenant, and signing up would run DDL inside a
  request.
