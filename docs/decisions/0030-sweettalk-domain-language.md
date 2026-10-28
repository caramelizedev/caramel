# ADR 0030: SweetTalk, an opt-in language for Domain-Driven Design on SugarORM and Cold Brew

Date: 2026-10-08

Status: accepted. Decisions 2, 4 and 6 are amended by
[ADR 0031](0031-sweettalk-services-processes-and-richer-values.md), decisions 1 and 6 by
[ADR 0033](0033-sweettalk-multi-tenancy.md), decision 2 by
[ADR 0035](0035-sweettalk-specifications-queries-and-state-checks.md), decisions 2 and 3
by [ADR 0036](0036-sweettalk-strategic-design.md), decision 6 by
[ADR 0041](0041-sweettalk-events-that-carry-attributes.md), and decision 3 by
[ADR 0044](0044-sweettalk-shared-kernels.md).

## Context

An application with a rich domain assembles Domain-Driven Design by hand from schemas,
changesets, actions and jobs. No word names a bounded context, an invariant, a domain event
or a policy, and nothing stops one context from reaching into another's types.

## Decision

1. **`require "caramel/sweet_talk"` is the only way in, and `include SweetTalk` scopes the
   words.** The code lives in `src/caramel/sweet_talk/`. A module that includes `SweetTalk`
   may use `context`, and a context's body the other words. No word is a top-level macro.
   `frappe make domain NAME CONTEXT --means=TEXT` starts one in `app/domain/`, required
   after the models.
2. **The words.**
   - **Contexts.** `context Name, follows: Other, means: "…" do … end` is a bounded context,
     a module; `follows: Other` lets it use `Other`'s types as they are. `border Other do …
     end` holds its only code that may name `Other::` without following it.
   - **Values.** `value Name, Int32, at_least:, at_most:, within:` (or `Int64`) is an
     immutable integer, validated when built and by every arithmetic result. `+` and `-`
     take the same value or an integer, `*` an integer, and `times: Other` lets `*` take
     `Other`, as in `Cents * Quantity`. Any other mix of values does not compile.
   - **Aggregates.** `aggregate Name do … end` is a root with an id, `Name::Id`, and a
     repository: `create`, `find`, `find?` and `all`. `entity Name` inside it is stored with
     it. `has name : Type` is an attribute (decision 4); `the name : Type = expression` is
     a derived value, never stored.
   - **Lifecycle and invariants.** `moves open >> placed >> shipped, placed >> cancelled`
     lists chains of states, the first state being the initial one. It adds a predicate per
     state and a private mover per later state, which refuses unless the current state
     comes just before it in a chain. `never "message" { condition }` refuses a command
     that leaves the condition true, and `always` one that leaves it false.
   - **Commands and events.** `to verb(arg : Type) do … end` is a command (decision 5), and
     `refuse "message"` ends it. `event Name, field : Type` declares one of the aggregate's
     events; `emit Name, field: value` queues one, and an aggregate emits only its own.
   - **Policies and projections.** `whenever Event do |event| … end`, in a context or a
     border, is a policy (decision 6). In `projection Name do … end` it updates rows, and
     `key name : Type` names the attribute that picks a row (decision 7).
   - **Renames.** `renamed_from: Old` on a context, aggregate, entity, event or projection
     keeps its table, its channel and its queued jobs.

   Every context, value, aggregate, entity, event and projection carries `means: "…"`, and
   one without it does not compile. `SweetTalk.glossary` lists them with kind and context.
3. **The context map is checked at compile time.** In context A, `follows: B` draws a
   dependency edge to B, and so does code in `border B` other than the event a `whenever`
   names; a `whenever` for one of B's events draws an event edge. A names `B::` or calls
   `B.verb` anywhere if it follows B, and only inside `border B` otherwise. An edge to an
   unknown context, a foreign name elsewhere, or a cycle of dependency edges does not
   compile, so two contexts may react to each other's events. `SweetTalk.context_map`
   returns the edges.
4. **Aggregates, entities and projections are SugarORM schemas.** Each generates a schema
   in `<Context>::Rows`, its table (`<context>_<name>` with an `s` added; an entity's is
   `<context>_<aggregate>_<entity>`), and a changeset with a `param` per column. Every
   write goes through that changeset
   ([ADR 0007](0007-sugarorm-schemas-changesets-preload.md)), and a context that names
   `Rows` does not compile. `has` stores:
   - `String`, `Int32`, `Int64`, `Bool`, `Float64` or `Time` as a column;
   - a value as its raw column, rebuilt and so validated on every load;
   - an aggregate as a foreign key, whose getter returns the aggregate's `Id`;
   - an `Array` of the aggregate's own entity as a child table, loaded with `preload`.

   Any other type does not compile. An entity updates only a row of the aggregate that
   saves it; a row another aggregate holds, or one a failed `create` or factory left, is
   inserted anew. A value or an aggregate is declared before the aggregate that stores it.
   A projection's table has a unique index on its key's column. `frappe db diff` derives
   the migrations ([ADR 0008](0008-branch-and-diff-migrations.md)).
5. **A command is one transaction on one aggregate.** `to` runs in
   `SugarORM::Repo.transaction`: it loads the aggregate with its root's row locked
   (SugarORM's `lock`), runs the body, checks every `never` and `always`, saves the root
   and then its entities, and dispatches the events. A `SweetTalk::Refusal` rolls the
   transaction back, and the aggregate reloads what is stored. A command or `create` on
   another aggregate while a command runs raises `SweetTalk::Boundary`, and so does a
   second one in a `whenever` handler.
6. **Events carry their facts and leave through Cold Brew, in the command's transaction.**
   - **Facts.** An event holds its subject's id (`order_id`) and its fields as they were
     when emitted: column types, values, ids and an `Array` of the aggregate's entity. No
     getter on an event loads an aggregate.
   - **Jobs.** The command enqueues one job per `whenever` that follows the event, carrying
     the event as JSON; `enqueue` joins the transaction
     ([ADR 0009](0009-cold-brew-queue-pubsub-cache.md) decision 2). `whenever Event, each:
     :lines do |event, line|` enqueues one job per element instead.
   - **Job names.** A job is named after its owner (a context and its border, or a
     projection) and the event's path as written; when a rename changes that name, the job
     declares Cold Brew's `renamed_from` with the old one, so queued jobs still run. An old
     name that another job has or claims does not compile. Two `whenever`s for one event in
     one owner do not compile.
   - **Retries.** A refusal or `SweetTalk::Boundary` fails a job at once. Other errors
     follow ADR 0009 decision 2.
   - **Notifications.** The command then publishes `{"subject": <id>}` on
     `sweettalk.<context>.<aggregate>.<event>`, each part underscored. A channel name over
     63 characters, or 42 in a program that requires `caramel/tenancy`, does not compile.
7. **A projection keeps one row per key.** In a `whenever` block, `Projection[key]` reads
   the key's row locked; when it is absent, a SugarORM upsert that does nothing on a
   conflict inserts it with its defaults, and the row is read locked again. The rows a
   handler touched are saved through their changeset when it returns.
8. **Checks.** SweetTalk's specs run against real PostgreSQL in `scripts/check
   integration`. Every refusal that decisions 2 to 6 promise has a fixture in a
   `sweet-talk-compilation` check that must fail to compile with its message.
   `frappe-project` derives a generated domain's tables with `frappe db diff` and runs its
   spec in `frappe corretto`. `page-boxoffice` builds the Box Office path's application
   from `spec/fixtures/pages/boxoffice` with the page's commands and runs its specs, and the
   website check holds the page's snippets to those files.

## Reasons

- A compiled glossary and a checked context map turn the drift Domain-Driven Design warns
  about into compile errors, with macros and no reflection. Contexts are modules in one
  binary, so one machine stays enough.
- `require` keeps SweetTalk out of an application that does not ask for it, as in
  [ADR 0024](0024-internationalization.md) and [ADR 0025](0025-multi-tenancy.md);
  `include` keeps the words out of every other module.
- Expanding into SugarORM and Cold Brew keeps state in PostgreSQL and one way to migrate.
  Enqueueing in the command's transaction is the outbox: an event is never lost or sent
  for a rolled-back change.
- An event records what happened. A handler that reloads its subject reads the present
  instead: a projection counted tins added to an order after checkout.
- The DDD Reference governs transactions by aggregate boundaries and updates across them
  asynchronously. One aggregate per transaction keeps each lock and each invariant its
  aggregate's own. A reference that yields an id makes a value needed at one moment, such
  as the price at checkout, an attribute captured then. The guard runs at run time,
  because a call's receiver type is unknown when a macro expands.
- Reacting to an event depends on its fields, not on the publisher's model. Counting only
  dependency edges lets contexts react to each other while their types point one way.
- Tins plus cents is a bug the compiler can catch.
- The row lock orders commands on one aggregate so each sees the last one's result,
  where a version column would fail the later one. A row lock cannot order the insert of
  a missing row, so a projection inserts it through an upsert that does nothing on a
  conflict.
- Refactoring toward deeper insight renames concepts, but tables, channels and queued jobs
  keep the names they were stored under; `renamed_from:` lets the code move on.
- Writes through `Rows` would skip invariants and the value checks made in Crystal.
- An entity's identity is its aggregate's: updating the row it was loaded from would move
  another aggregate's entity, and a row a rolled-back write left no longer exists.
- A notification carries an id, as Cold Brew advises: fields could pass its 8,000-byte
  limit, and the refused publish would roll the command back.

Rejected:

- **Top-level words.** They would catch any `context(…)` call in an application.
- **Policies inside the publishing command.** A policy's refusal would reach the client
  after the first change had been kept.
- **Restoring an in-memory snapshot after a refusal.** Inside savepoints, only the
  database is certainly right.
- **`Hash` attributes.** An entity holds that data in rows.
- **A separate repository.** SweetTalk expands into macro contracts that
  [ADR 0016](0016-versioning-and-releases.md) does not cover.
