# ADR 0064: Records are keyed by a UUIDv7 the application mints, with Int64 as an opt-in

Date: 2026-11-07

Status: accepted. Amends [ADR 0003](0003-core-routing-and-contracts.md) decision 1,
[ADR 0007](0007-sugarorm-schemas-changesets-preload.md) decisions 1 and 2,
[ADR 0020](0020-action-ingress-and-json-bodies.md) decision 4,
[ADR 0024](0024-internationalization.md)'s key table,
[ADR 0025](0025-multi-tenancy.md) decisions 6 and 7,
[ADR 0030](0030-sweettalk-domain-language.md) decisions 4 and 6,
[ADR 0031](0031-sweettalk-services-processes-and-richer-values.md) decision 3,
[ADR 0033](0033-sweettalk-multi-tenancy.md) decisions 6 and 7,
[ADR 0034](0034-sweettalk-at-the-web-boundary.md) decisions 3 and 4,
[ADR 0048](0048-sweettalk-event-log.md) decisions 2 and 3,
[ADR 0049](0049-sweettalk-sums-and-groups.md) decision 3,
[ADR 0050](0050-sweettalk-nested-entities.md) decisions 2 and 4,
[ADR 0052](0052-sugarorm-conflicts-retries-and-reads-at-scale.md) decision 6,
[ADR 0053](0053-sweettalk-create-announces-created.md) decision 4 and
[ADR 0060](0060-sweettalk-preview-and-commit.md) decision 3.

## Context

Every record was keyed by an `Int64` identity column, so a record had no id until its row
was written. An application could not name a record before the insert: not in an event
built beside it, not in a job queued in the same step, not in a URL handed out first.
Sequential ids also tell anyone who sees one how many records exist.

The choices made:

1. `Int64` stays available as an opt-in. UUIDv7 is the default for generated resources and
   tenants and for SweetTalk.
2. A UUID primary key has the database default `uuidv7()`, so PostgreSQL 18 is the floor
   for UUID-keyed tables.
3. Tenants are UUID-keyed too.
4. A client supplies an id only through a changeset that declares `param id`.

## Decision

1. **Two key types.** `field id : UUID, primary: true` is a
   `uuid NOT NULL DEFAULT uuidv7() PRIMARY KEY` column; `field id : Int64, primary: true`
   stays a bigint identity column the database assigns. Any other primary key fails
   compilation. Each schema declares `alias PrimaryKey` and `SUGAR_KEY`; `find`, `find!`,
   `page(after:)` and `each_batch` take `PrimaryKey`, and `SugarORM::Page(R, K)` carries the
   key type. `UUID` and `UUID?` are ordinary field types too: rangeable in `where`, with no
   default. Caramel checks no server version: PostgreSQL before 18 fails the `CREATE TABLE`
   with its own error.
2. **The changeset mints the id.** An insert changeset of a UUID-keyed schema takes its id
   from `SugarORM.uuid7` when it is built; `changeset.id` returns it and `changes` lists it.
   `SugarORM.uuid7` implements RFC 9562 method 3: a 48-bit millisecond time, 12 bits of
   sub-millisecond time, and 62 random bits; each id is greater than the last this process
   minted, even when the clock stalls or steps back. An Int64-keyed changeset's `id` raises
   `SugarORM::Error` before the insert. A raw `INSERT` that names no id gets `uuidv7()`.
3. **`param id` is the only client path.** A changeset that declares `param id : UUID`
   takes a client's id, and only a UUID key allows it: `param id` on an Int64 key fails
   compilation. A taken id is `id: has already been taken`. An update that changes the id
   is `id: cannot be changed` (`errors.key_kept`). `DefaultChangeset` and the facade never
   take an id.
4. **Foreign keys follow their target.** A `belongs_to` or `tenant` column is `uuid` or
   `bigint` after its target's key, and the target may be declared later in the program; a
   `param` for it is checked once the program is complete.
5. **One spelling binds.** A contract field or route parameter of type `UUID` binds from
   the canonical lowercase hyphenated form only. Other text is a field error, and a path
   parameter that does not bind answers 404. `min:` and `max:` on a `UUID` fail
   compilation. `<singular>_path(id : UUID)` builds a resource path from a UUID.
6. **The tenant prefix.** A UUID tenant's cache and channel prefix is `t`, the UUID as 25
   lowercase base-36 characters (`Caramel::ColdBrew.short_id`), and `:`: 27 characters. An
   Int64 tenant keeps `t<digits>:`. A job carries `"caramel_tenant"` as a JSON number for an
   Int64 tenant and a string for a UUID tenant, so a queued Int64 payload reads as before.
7. **SweetTalk ids.** `ids Int64`, before the first context, keys a domain's aggregates and
   entities by an Int64 the database assigns. Otherwise a domain's ids follow its tenant's
   key type, or are UUID without a tenant. A domain whose `ids` differ from its tenant's key
   fails compilation. In a UUID domain an aggregate or entity gets its id when built, so
   `id`, `==` and `hash` work before `create`, and entities come back in creation order; a
   copied or rolled-back entity inserted again takes a fresh id. `Name::Id` binds from the
   domain's id type; `has x : UUID` is a stored column; the event log's `subject_id` takes
   the context's id type.
8. **The channel budget.** An event channel holds at most 63 characters less the tenant
   prefix: 42 under an Int64 tenant, 36 under a UUID tenant, 63 without `caramel/tenancy`.
9. **Tables that stay bigint.** `caramel_jobs`, `caramel_migrations`, `<context>_operations`,
   each context's event log id, projection rows and process rows keep
   `field id : Int64, primary: true`.
10. **Frappé.** `frappe make resource` and `frappe make tenancy` write UUID keys;
    `--int64` writes an Int64 key. A tenant resource's `<tenant>_id` column follows the
    tenant model's `field id` line. `frappe make domain` writes no `ids` line.

## Reasons

- An id the application holds before the insert lets one step name a record in events,
  jobs, URLs and child rows without a round trip, and SweetTalk aggregates compare and hash
  before they are saved.
- UUIDv7 leads with time, so new keys land at the right of a B-tree index as a sequence's
  do, and ordering by id stays roughly creation order. A random UUIDv4 scatters inserts
  across the index.
- **Rejected: the stdlib `UUID.v7`.** It has no counter, so two ids in one millisecond
  order at random; the sub-millisecond bits and the per-process floor keep a process's ids
  strictly increasing, which entity order relies on.
- **Rejected: the database alone mints the id.** The application would again wait for
  `RETURNING` to learn the key. `uuidv7()` stays as the column default so raw SQL and other
  writers still get a v7 key.
- **Rejected: a version check for PostgreSQL 18.** On an older server the first migration
  that creates a UUID-keyed table already fails with `function uuidv7() does not exist`; a
  check would add a query at every start to report the same thing.
- **Rejected: taking an id from any changeset.** An id a form could set lets a client pick
  or overwrite keys; one declared `param id` makes the choice visible and reviewable.
- **Rejected: any UUID spelling in routes.** Uppercase, braced or unhyphenated forms would
  give one record several URLs, splitting caches and links.
- **Rejected: the hyphenated UUID as the tenant prefix.** At 38 characters it would leave a
  channel 25; base 36 fits the 128 bits in 25 characters and keeps the prefix's alphabet of
  digits and lowercase letters, so the cache patterns stay exact.
- **SweetTalk ids follow the tenant** because an event keeps the tenant's id where its
  aggregate ids go; a mismatch is refused at compile time rather than at the first write.
- **Bigint stays where order or a counter is the point.** The event log's id is the rebuild
  cursor, read in order; projection and process rows are named by their key, never their
  id; jobs and migrations are framework bookkeeping no application id refers to.
- **Rejected: switching existing domains silently.** A SweetTalk domain without a tenant now
  defaults to UUID; `frappe db diff` halts on the changed key and its remediation names
  `ids Int64`, so no table is rewritten by accident.
