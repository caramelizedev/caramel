# ADR 0025: Multi-tenancy is opt-in: one require scopes an application's rows to the tenant the first path segment names

Date: 2026-10-03

Status: accepted.

## Context

An application that serves several organizations must keep each one's rows apart. It must be able to opt in, pay nothing when it does not, and plug tenancy in and out again. A tenant is a record like any other, so it is keyed by a UUID or by an Int64 ([ADR 0007](0007-sugarorm.md)), and its id appears in every cache key, PubSub channel and job payload its work writes. The guide starts at `site#c-tenancy-map`.

## Decision

1. **One require is the only way in, and it replaces hooks that core defines as identities.** Core routes requests, builds paths, names cache keys and channels and writes job payloads through hooks that do nothing. The tenancy require redefines them, and a program that has the require and declares no tenant does not compile. How SweetTalk follows the tenant is in [ADR 0033](sweettalk/0033-framework-boundary.md).
2. **Tenants share one database and one schema, and a tenant column scopes each row.** A schema opts in with one declaration: a `belongs_to` to the tenant that also scopes. SugarORM manages the column; a changeset never sets it.
3. **Scoping fails closed.** With a tenant bound, every statement SugarORM builds for a tenanted schema carries the tenant. With none bound it raises. Working across tenants is an explicit block, and raw SQL is not scoped.
4. **The tenant is bound to the fiber for a block and restored afterwards.** A request outside a tenant routes with none bound, and a fiber the application spawns starts with none.
5. **The first path segment names the tenant.** The router takes one tenant block, which names the tenant model, its slug field and the tenant's routes. A slug is a DNS label, and the tenant comes before a locale prefix.
6. **A tenant route fails closed.** A route in the tenant block does not compile unless its action names an authenticator or declares itself open to anyone in the tenant, through the ingress declaration of [ADR 0003](0003-routing-and-ingress.md).
7. **Membership is the application's.** Tenancy decides which rows a request sees. Whether a user may act in a tenant is the application's ingress check; the generated session-held membership is a starting point the application replaces with a table of its own.
8. **PostgreSQL keeps a reference inside its tenant.** A foreign key between two tenanted tables is composite and includes the tenant column, and a unique index is unique per tenant. The catalog and the migration differ therefore handle foreign keys of several columns.
9. **A tenant is keyed by UUID, or by Int64 as an opt-in.** The tenant column of every tenanted table follows the tenant's key type.
10. **A job runs in the tenant it was enqueued in.** Its payload carries the tenant's id in the id's own JSON type. A job whose tenant is gone fails; it does not run unscoped.
11. **Cache keys and PubSub channels carry the bound tenant's prefix.** A UUID is written in base 36 inside the prefix. With no tenant bound, a name that reads as prefixed is refused.
12. **Frappé generates the tenant, then resources that belong to it.** After the tenancy generator has run, a generated resource belongs to the tenant unless it is asked to be central, shared by every tenant. The tenancy generator edits no library's code: a library whose code must name the tenant refuses to compile until it does.
13. **Tenancy plugs into existing data, and out again, by hand.** The differ halts on a populated table that gains a tenant; it does not guess which tenant owns existing rows. No command removes tenancy.

## Reasons

- One require over identity hooks means a plain application compiles none of the tenancy code. [ADR 0024](0024-internationalization.md) enters i18n the same way.
- Scoping fails closed because the alternative leaks. Crystal applications today scope with an explicit `where`, and one forgotten call shows another tenant's rows; Ecto's `prepare_query`, Ash and activerecord-tenanted raise instead.
- Tenant routes fail closed for the same reason. The slug alone selects the tenant and the session cookie spans every tenant, so a user signed in under one tenant reached another's pages until each action checked membership by hand ([#99](https://github.com/caramelizedev/caramel/issues/99)).
- Composite keys let PostgreSQL refuse a reference to another tenant's row, even from raw SQL, and the index they rest on serves scoped reads.
- The tenant is bound per fiber and restored, as `Log.with_context` is, because HTTP::Server serves keep-alive requests on one fiber. A reused fiber must carry no tenant into the next request.
- A path prefix needs no DNS or certificates in development, and the slug is a DNS label, so subdomains can follow without changing application code.
- A job carries each tenant id in its own JSON type so that a payload reads the same whichever key type the tenant has.
- A generator that edited a library's files would have to know each library's layout, and it would miss code written after it ran. A compile error reaches every such file, whenever it was written, and names the edit.
- Rejected: the hyphenated UUID as the tenant prefix. It leaves too little of PostgreSQL's channel name; base 36 is shorter and keeps the prefix to digits and lowercase letters, so cache patterns stay exact.
- Rejected: subdomains as the first way to name a tenant. They need wildcard DNS and certificates before the first page works.
- Rejected: a schema per tenant. SugarORM checks out a pooled connection per statement and caches prepared statements; introspection, migrations, Corretto, Latte and Cold Brew all assume one schema; and signing up would run DDL inside a request.
- Rejected: a database per tenant. It multiplies pools, migrations and backups.
- Rejected: row-level security as the first layer. Owners bypass it without FORCE, and the setting must be bound per transaction, since crystal-db sets a connection up only when it opens one.
- Rejected: explicit scope arguments, as in Phoenix, or `where(org_id: …)`. Both fail open when one call forgets.
- Rejected: `tenant: true` on path helpers, and a separate configuration declaration. The router's tenant block already names the model, the slug and the tenant routes.
- Deferred: host-based identification, and row-level security as a second layer.
