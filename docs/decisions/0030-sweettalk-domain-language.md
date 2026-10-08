# ADR 0030: SweetTalk, an opt-in language for Domain-Driven Design on SugarORM and Cold Brew

Date: 2026-10-08

Status: proposed. It is accepted in the commit that adds `src/caramel/sweet_talk/` with its
specs and its line in [ADR 0014](0014-repository-layout.md); until then none of it is in
force.

## Context

An application with a rich domain assembles Domain-Driven Design by hand from schemas,
changesets, actions and jobs. No word names a bounded context, an invariant, a domain event
or a policy, and nothing stops one context from reaching into another's types.

## Decision

1. **`require "caramel/sweet_talk"` is the only way in, and `include SweetTalk` scopes the
   words.** The code lives in `src/caramel/sweet_talk/`, and a program that does not
   require it compiles none of SweetTalk. A module that `include`s `SweetTalk` may use
   `context`, and a context's body may use the other words. No word is a top-level macro.
2. **The words.**
   - **Contexts.**
     - `context Name, follows: Other, means: "…" do … end` is a bounded context, a module.
       `follows: Other` lets it use `Other`'s types as they are.
     - `border Other do … end`, inside a context, holds that context's only code that may
       name `Other::` without following it.
   - **Values and aggregates.**
     - `value Name, Int32, at_least:, at_most:, within:` (or `Int64`) is a value object:
       an immutable integer, validated when it is built and by every arithmetic result.
     - `aggregate Name do … end` is an aggregate root with an id and a repository:
       `create(**attributes)`, `find(id)`, `find?(id)` and `all`.
     - `entity Name do … end`, inside an aggregate, is an entity stored with it.
     - `has name : Type` is an attribute, stored as decision 4 says.
     - `the name : Type = expression` is a derived value, computed on every read and never
       stored.
   - **Lifecycle and invariants.**
     - `moves a >> b >> c` is the lifecycle. It adds a stored state, the predicates `a?`,
       `b?` and `c?`, and the private movers `b!` and `c!`. Each mover refuses unless the
       current state is the one before it.
     - `never "message" { condition }` refuses a command that leaves the condition true,
       and `always "message" { condition }` one that leaves it false.
   - **Commands and events.**
     - `to verb(arg : Type) do … end` is a command (decision 5). Inside it, `refuse
       "message"` raises `SweetTalk::Refusal` and ends the command.
     - `event Name, field : Type` declares one of the aggregate's events. `emit Name,
       field: value`, inside a command, queues one; an aggregate emits only its own events.
     - `whenever Event do |event| … end`, in a context or a border, is a policy (decision
       6). In a projection it updates rows (decision 7).
   - **Projections.** `projection Name do … end` is a read model, and `key name : Type`
     names the attribute that picks its row.

   Every context, value, aggregate, entity, event and projection carries `means: "…"`, and
   one without it does not compile. `SweetTalk.glossary` lists every entry with its kind and
   context.
3. **The context map is checked at compile time.** In context A, `follows: B` and
   `border B` each draw an edge from A to B. A may name `B::` anywhere if it follows B, and
   only inside `border B` otherwise. An edge to an unknown context, a foreign name
   elsewhere, or a cycle of edges does not compile. `SweetTalk.context_map` returns the
   edges.
4. **Aggregates, entities and projections are SugarORM schemas.** Each generates:
   - a schema in `<Context>::Rows`;
   - its table, `<context>_<name>` with an `s` added (an entity's table is
     `<context>_<aggregate>_<entity>`, likewise);
   - a changeset with a `param` per column.

   Every write goes through that changeset
   ([ADR 0007](0007-sugarorm-schemas-changesets-preload.md)). `has` stores:
   - `String`, `Int32`, `Int64`, `Bool`, `Float64` or `Time` as a column;
   - a value as its raw `Int32` or `Int64` column, rebuilt and so validated on every load;
   - an aggregate as a `belongs_to` with a foreign key;
   - an `Array` of the aggregate's own entity as a child table, loaded with `preload`.

   Any other type does not compile. A value or an aggregate is declared before the
   aggregate that stores it. A projection's table has a unique index on its key's column.
   The schemas are ordinary SugarORM schemas, so `frappe db diff` derives their migrations
   ([ADR 0008](0008-branch-and-diff-migrations.md)).
5. **A command is one transaction.** `to` runs in `SugarORM::Repo.transaction`:
   1. lock the root's row with `SELECT … FOR UPDATE`;
   2. reload the aggregate;
   3. run the body;
   4. check every `never` and `always`;
   5. save the root, then its entities;
   6. dispatch the events.

   A `SweetTalk::Refusal` rolls the transaction back, and the aggregate reloads what is
   stored. `create` checks the invariants, then inserts the root and its entities, in one
   transaction.
6. **Events leave through Cold Brew, in the command's transaction.**
   - **Jobs.** For each event, the command enqueues one job per `whenever` that follows
     it. `enqueue` joins the transaction ([ADR 0009](0009-cold-brew-queue-pubsub-cache.md)
     decision 2). A job carries the subject's id and the event's fields as JSON.
   - **Job names.** A job is named after its owner (a context and its border, or a
     projection) and the event's path, never after a line number, because `caramel_jobs`
     stores the name. Two `whenever` blocks for the same event in one border, context body
     or projection do not compile.
   - **Retries.** Each job declares `retry_on SweetTalk::Refusal, attempts: 1`, so a
     refusal fails it at the first attempt. Other errors follow ADR 0009 decision 2.
   - **Notifications.** The command then publishes `{"subject": <id>}` on
     `sweettalk.<context>.<aggregate>.<event>`, each part underscored. A channel name over
     63 characters does not compile, and the payload never approaches Cold Brew's
     8,000-byte limit.
7. **A projection keeps one row per key.** In a `whenever` block, `Projection[key]` runs
   `INSERT … ON CONFLICT DO NOTHING` on the key's column, then `SELECT … FOR UPDATE`, then
   loads the row. The rows a handler touched are saved through their changeset when the
   handler returns.
8. **Checks.** SweetTalk's specs run against real PostgreSQL in `scripts/check
   integration`. Every refusal that decisions 2 to 6 promise has a fixture in a
   `sweet-talk-compilation` check that must fail to compile with its message, as
   `orm-compilation` holds SugarORM's.

## Reasons

- A compiled glossary and a checked context map turn the drift Domain-Driven Design warns
  about (a term that changes meaning, a context that reaches into another) into compile
  errors, with macros and no reflection.
- Contexts are modules in one binary, and a border is an anticorruption layer without a
  network, so one machine stays enough.
- `require` keeps SweetTalk out of an application that does not ask for it, as the opt-ins
  of [ADR 0024](0024-internationalization.md) and [ADR 0025](0025-multi-tenancy.md) do.
  `include` then keeps the words out of every module but the ones that use them, so no
  call elsewhere can reach a SweetTalk macro.
- Expanding into SugarORM and Cold Brew keeps state in PostgreSQL, keeps one way to
  migrate, and brings no broker. Enqueueing in the command's transaction is the outbox,
  so an event is never lost or sent for a rolled-back change.
- SugarORM updates a row by its id with no version column. Without the row lock, a second
  command on the same aggregate writes from a stale read; with it, commands on one
  aggregate run one after another, and each sees the last one's result. The lock is SQL
  because SugarORM's query API has none.
- A row lock cannot serialize the insert of a row that does not exist yet. The unique index
  and `ON CONFLICT DO NOTHING` let two handlers that meet a new key both arrive at one row,
  and the lock then orders them.
- Policies and projections run after the command commits, as the DDD Reference advises
  for updates across aggregate boundaries. A job's own writes commit once with its
  completion ([ADR 0019](0019-cold-brew-status-hooks-and-work.md) decision 4), so a
  handler that only writes PostgreSQL needs no deduplication. A refusal is
  deterministic, so retrying it only delays the failure.
- A job name is stored with every queued job. A name taken from a line number would
  strand queued jobs on the next edit above the handler.
- A notification names the event in its channel and the record by id; readers load the
  record, as Cold Brew's payload error advises. A payload holding the fields could pass
  the 8,000-byte limit, and the refused publish would roll the command back.

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
