# ADR 0030: SweetTalk, an opt-in language for Domain-Driven Design on SugarORM and Cold Brew

Date: 2026-10-08

Status: proposed.

## Context

An application with a rich domain assembles Domain-Driven Design by hand from schemas,
changesets, actions and jobs. No word names a bounded context, an invariant, a domain event
or a policy, and nothing stops one context from reaching into another's types. This
decision covers SweetTalk's domain words. Its web words (`resource`, `represent`, `guard`,
`on`, `watch`) are a later decision.

## Decision

1. **`require "caramel/sweet_talk"` is the only way in.** The code lives in
   `src/caramel/sweet_talk/` ([ADR 0014](0014-repository-layout.md)). A module that
   `include`s `SweetTalk` may use `context`, and a context's body may use the other words.
   No word is a top-level macro.
2. **The words.**
   - `context`, with `follows:`, and `border`;
   - `value`, `aggregate`, `entity`, `projection` and `key`;
   - `has`, `the`, `moves`, `never` and `always`;
   - `to`, `refuse`, `event`, `emit` and `whenever`.

   Every context, value, aggregate, entity, event and projection carries `means:`, and one
   without it does not compile. `SweetTalk.glossary` lists every entry with its kind and
   context.
3. **The context map is checked at compile time.** A context names another context's
   types only when it `follows:` that context, or inside a `border` with it. An unknown
   context, a foreign name anywhere else, or a cycle of `follows:` and borders does not
   compile. `SweetTalk.context_map` returns the edges.
4. **Aggregates, entities and projections are SugarORM schemas.** Each generates:
   - a schema in `<Context>::Rows`;
   - its table, `<context>_<name>`, with an `s` added (an entity's table is
     `<context>_<aggregate>_<entity>`, also with an `s`);
   - a changeset with a `param` per column.

   Every write goes through that changeset
   ([ADR 0007](0007-sugarorm-schemas-changesets-preload.md)). `has` stores:
   - `String`, `Int32`, `Int64`, `Bool`, `Float64` or `Time` as a column;
   - a value as its raw `Int32` or `Int64` column, rebuilt and so validated on every load;
   - an aggregate as a `belongs_to` with a foreign key;
   - an `Array` of the aggregate's own entity as a child table, loaded with `preload`.

   Any other type does not compile. A value or an aggregate is declared before the
   aggregate that stores it. The schemas are ordinary SugarORM schemas, so `frappe db
   diff` derives their migrations ([ADR 0008](0008-branch-and-diff-migrations.md)).
5. **A command is one transaction.** `to` runs in `SugarORM::Repo.transaction`:
   1. lock the root's row with `SELECT … FOR UPDATE`;
   2. reload the aggregate;
   3. run the body;
   4. check every `never` and `always`;
   5. save the root, then its entities;
   6. dispatch the events.

   A `SweetTalk::Refusal` rolls the transaction back, and the aggregate reloads what is
   stored. `create` checks the invariants before it inserts. Lifecycle movers (`placed!`)
   are private, so only the aggregate's commands move its state.
6. **Events leave through Cold Brew, in the command's transaction.** For each event, the
   command enqueues one job per `whenever` that follows it
   ([ADR 0009](0009-cold-brew-queue-pubsub-cache.md)). It then publishes on
   `sweettalk.<context>.<aggregate>.<event>`.
   - **Payload.** A job carries the subject's id and the event's fields as JSON.
   - **Name.** A job is named after its owner (a context and its border, or a projection)
     and the event's path, never after a line number, because `caramel_jobs` stores the
     name. Two `whenever` blocks for the same event in one border, context body or
     projection do not compile.
   - **Retries.** A refusal fails its job at the first attempt. Other errors follow Cold
     Brew's retry rules ([ADR 0019](0019-cold-brew-status-hooks-and-work.md)).
7. **A projection is a table with one row per key.** `key` names the attribute that picks
   the row. In a `whenever` block, `Projection[key]` inserts the row with its defaults when
   it is absent and locks it. The rows a handler touched are saved through their
   changeset when the handler returns.
8. **SweetTalk's specs run against real PostgreSQL** in `scripts/check integration`. Every
   refusal the words promise has a fixture that must fail to compile with its message.

## Reasons

- A compiled glossary and a checked context map turn the drift Domain-Driven Design warns
  about (a term that changes meaning, a context that reaches into another) into compile
  errors, with macros and no reflection.
- Contexts are modules in one binary, and a border is an anticorruption layer without a
  network, so one machine stays enough.
- Expanding into SugarORM and Cold Brew keeps state in PostgreSQL, keeps one way to
  migrate, and brings no broker. Enqueueing in the command's transaction is the outbox,
  so an event is never lost or sent for a rolled-back change.
- SugarORM updates a row by its id with no version column. Without the row lock, a second
  command on the same aggregate writes from a stale read; with it, commands on one
  aggregate run one after another, and each sees the last one's result. The lock is SQL
  because SugarORM's query API has none.
- Policies and projections run after the command commits, as the DDD Reference advises
  for updates across aggregate boundaries. A job's own writes commit once with its
  completion (ADR 0019), so a handler that only writes PostgreSQL needs no deduplication.
  A refusal is deterministic, so retrying it only delays the failure.
- A job name is stored with every queued job. A name taken from a line number would
  strand queued jobs on the next edit above the handler.
- The words are scoped by `include`, as the opt-ins of
  [ADR 0024](0024-internationalization.md) and
  [ADR 0025](0025-multi-tenancy.md) are by `require`, so an application that does not use
  them compiles none of them.

Rejected:

- **Top-level words.** They would catch every `context(…)` or `resource(…)` call in an
  application and its shards.
- **Aggregates kept in memory, and policies run inside the command that publishes.** A
  policy's refusal would reach the client after the first change had already been kept.
- **Restoring an in-memory snapshot after a refusal.** Inside nested savepoints, the
  database is the only state that is certainly right.
- **`Hash` attributes.** They have no column; an entity holds the same data in rows.
- **A separate repository.** SweetTalk expands into SugarORM's and Cold Brew's macro
  contracts, which [ADR 0016](0016-versioning-and-releases.md) does not cover, so it has
  to change in the same commit as they do.
- **Deferred:** a column type for values and `CHECK` constraints for their bounds, a
  public row lock in SugarORM, tenant-scoped repositories and channels, and compensation
  for a failed policy.
