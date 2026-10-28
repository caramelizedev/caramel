# ADR 0033: SweetTalk multi-tenancy

Date: 2026-10-11

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decisions 1 and 6
and [ADR 0031](0031-sweettalk-services-processes-and-richer-values.md) decision 11, and
applies [ADR 0025](0025-multi-tenancy.md) to SweetTalk.

## Context

ADR 0030 refuses a program that requires both `caramel/sweet_talk` and `caramel/tenancy`,
because SweetTalk scoped no table, key or channel by tenant. A multi-tenant application
needs its domain in SweetTalk too. SweetTalk stores every row through SugarORM schemas, and
SugarORM and Cold Brew already follow the bound tenant once a schema declares `tenant`. What
remains is which rows belong to a tenant, and which combinations would leak across tenants.

## Decision

1. **The domain names its tenant** (amends ADR 0030 decision 1). In a program that requires
   `caramel/tenancy`, the module that includes `SweetTalk` says `tenant App::Account`
   before its first context. The model is the one the routes' `tenant` block names, and
   SugarORM refuses another. A domain without it does not compile, nor does `tenant`
   without the require, after a context, twice, or naming anything but a SugarORM schema.
   `frappe make tenancy` names the tenant in each domain in `app/domain/`, and
   `frappe make domain` in a multi-tenant application names it in the new domain;
   `--central` marks its first context `central: true`.
2. **Every context is tenanted unless it says `central: true`.** A tenanted context's
   aggregates, entities, projections and processes declare SugarORM's
   `tenant account : App::Account` (ADR 0025 decision 4); the attribute is named after the
   model's last segment. Their reads, locks, keys and unique indexes are per tenant: a
   projection or a process keeps one row per tenant per key, and an entity's parent key is
   composite. `context Name, central: true` keeps its rows shared by every tenant, as
   `frappe make resource --central` does. `central:` takes only `true`, and only in a
   program that requires `caramel/tenancy`.
3. **Jobs and channels follow the tenant.** A policy, projection or process step runs in
   the tenant its event was emitted in, and a deadline in the tenant that armed it; either
   fails with `Caramel::Tenancy::Gone` once that tenant is gone (ADR 0025 decision 6). A
   notification is published on the tenant's prefixed channel.
4. **References point from a tenant to shared data, not back.** A tenanted aggregate may
   `has` a central aggregate, through a plain foreign key. A central context may not `has`
   a tenanted aggregate or a tenanted application schema.
5. **Shared events do not drive a tenant's rows.** A `whenever` in a tenanted context or
   border that follows a central context's event does not compile, because that event
   carries no tenant. A central context may follow a tenanted context's events; its
   handler runs in the event's tenant and writes shared rows.
6. **Names fit PostgreSQL** (amends ADR 0030 decision 6 and ADR 0031 decision 11). In a
   program that requires `caramel/tenancy`, a channel name over 42 characters does not
   compile, which leaves 21 for the `t<id>:` prefix. A tenanted table's tenant index,
   `index_<table>_on_<model>_id_and_id` (`account_id` for `App::Account`), does not
   compile over 63 bytes, and in every program neither does a reference's or a key's index.
7. **The tenant's column is reserved, and the aggregate names it.** A `has` or a composite
   part that would store `<model>_id` (`account_id` for `App::Account`), and an entity
   whose aggregate is named like the tenant model, do not compile. Every aggregate of a
   tenanted context has `tenant_id : Int64`, its row's, or the bound tenant's before its
   first save, and `tenant`, the tenant model's row, so rows read under
   `Caramel::Tenancy.without` still say whose they are; `has tenant` or `has tenant_id`
   on such an aggregate does not compile.
8. **Plugging in on existing data** follows ADR 0025's steps, and `frappe db diff` halts on
   each SweetTalk table they apply to. Every queue is drained before the first deploy with
   tenancy, because a job enqueued without a tenant runs with none.
9. **Checks.** `scripts/check integration` runs a fourth spec program,
   `spec/sweet_talk_tenancy`, whose domain mixes tenanted and central contexts, while
   `spec/sweet_talk` keeps running without tenancy. Every refusal above has a
   `sweet-talk-compilation` fixture, and `compile_with_tenancy` is a valid case.

## Reasons

- Tenancy by default fails closed, as ADR 0025 requires: a context left unmarked hides its
  rows from other tenants instead of sharing them. A bounded context is the unit of
  language and ownership, so the context decides.
- A generated application requires its models before its routes. Read from the routes
  while a schema expands, the tenant model is not yet known in that order, and the domain
  compiles untenanted. Schemas generated in `macro finished` would see it, but every
  SweetTalk schema would expand last and a clash would point into generated code. The
  explicit word works in any order, and SugarORM already checks the duplicated name.
- One `tenant` line per schema is the whole run-time change: SugarORM scopes reads, locks,
  upserts and keys, and Cold Brew carries the tenant into jobs and deadlines.
- A central row that names tenanted rows shows their ids to every tenant. A central event's
  tenanted handler fails with `SugarORM::Tenancy::Missing`, or writes into whichever tenant
  the central command happened to run in. A refusal can be lifted later without breaking a
  program; one added after a release would break programs.
- Tenant ids only grow, so the channel budget subtracts the longest prefix. PostgreSQL
  truncates an index name over 63 bytes, and the differ then drops the tenant index in its
  next plan.
- A column named after the model matches the application's own tenanted tables, so SQL,
  `frappe db diff` and ADR 0025's plug-in steps read the same.
- Each opt-in already has a spec program of its own, and `spec/sweet_talk` keeps proving
  SweetTalk without tenancy.

Rejected:

- **Opt-in `tenanted: true`.** One forgotten flag shares a context's rows between tenants.
- **`central:` per aggregate.** One context's invariants would span tenants.
- **Requiring the domain after the routes.** Any other order compiles untenanted.
- **Hashed channel names.** Live pages and `renamed_from:` rely on readable channels.
- **A generator for the plug-in migrations.** It would cover only a one-tenant backfill.
- **Deferred:** a central event delivered to every tenant, an `as:` name for the tenant
  attribute, and a SugarORM refusal of every index name over 63 bytes.
