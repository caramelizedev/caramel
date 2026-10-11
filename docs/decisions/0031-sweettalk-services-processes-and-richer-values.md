# ADR 0031: SweetTalk services, factories, queries, richer values and processes

Date: 2026-10-09

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decisions 2, 4 and 6.

## Context

ADR 0030 gives SweetTalk contexts, integer values, aggregates, events, policies and
projections. A domain also needs operations that belong to no one aggregate, ways to make,
find and retire aggregates, values that are strings or have several parts, references to
an application's own schemas, events that say who acted, and workflows that span
aggregates over days and undo their work when a step is refused.

## Decision

1. **Values** (amends decision 2).
   - `value Name, String, matches: /…/, length: 3..254` is a string value. A string value
     takes only `matches:` and `length:`, an integer value only `at_least:`, `at_most:`,
     `within:` and `times:`, and only integer values have arithmetic.
   - `value Name, means: "…" do part street : String; … end` is a composite value. A part
     is a column type or a value that wraps one. It is built with one keyword per part,
     checks its `never` and `always` when built, and equals another with the same parts.
   - Any other value does not compile.
2. **Attributes and tables** (amends decision 4).
   - `has name : Type = expression` gives an aggregate's or an entity's attribute a default;
     its column has a SQL default when the expression is a literal. A projection's or a
     process's attributes other than its key are nilable or have a literal default.
   - A composite value is stored one column per part, `<attribute>_<part>`.
   - `has member : Account`, where `Account` is an application's SugarORM schema, is a
     foreign key whose getter returns `SweetTalk::RecordId(Account)`; `load` reads it.
   - Table names take English plurals (`shelf_boxes`). An entity's parent column is named
     after its aggregate's stored name, so it survives a rename.
3. **Repositories.**
   - `find`, `find?`, `all` and every query read one statement per table: the roots, then
     each list of entities through `preload`. Saving deletes dropped entities in one
     statement.
   - `finds verb(args), where: {attribute: expression, state: :placed}` in an aggregate is a
     query: the aggregates whose columns equal the expressions (a list matches any member,
     a range its span), by id. A key that names no stored attribute, a list of entities, or
     a state the lifecycle lacks does not compile.
   - `remove` in a command retires the aggregate: its row stays with `removed_at` set, and
     `find`, `find?`, `all`, every query and the command's row lock skip it.
4. **Factories.** `factory verb(args) do … end` in an aggregate makes one. Arguments named
   like attributes set them; the body runs as the aggregate's first change and may `emit`;
   the aggregate is checked, saved and its events dispatched in one transaction. An
   aggregate with a factory has no `create`. An attribute that no argument sets and no
   default covers, or a factory named like a repository method, does not compile.
5. **Services.** `service verb(args), returns: T, means: "…" do … end` in a context is a
   domain service and a glossary entry. It runs in one transaction and changes at most one
   aggregate. Anywhere but a context it does not compile.
6. **Event metadata** (amends decision 6). Every event records `event_id`, `occurred_at`
   and `actor`, and its jobs carry them. `SweetTalk.acting(by) { … }` names the actor of
   the events emitted inside it, and each policy, compensation and step runs as its
   event's actor. A field may be nilable, as in `reason : String?`, but not another union;
   a field named like the metadata or the subject's id does not compile. An event reads
   its subject's id when it is dispatched, so a factory's event names the new aggregate.
   A retried job restores the same `event_id`, the key a handler gives a side effect
   outside PostgreSQL, such as mail, so a retry can tell it already happened.
7. **Compensation** (amends decision 6). `compensate Event do |event, …, refusal| … end`,
   after a `whenever` for the same event in the same context, border or process, runs when
   that handler is refused. The handler's work has rolled back; the compensation gets its
   arguments and the refusal, and runs in its own transaction, changing at most one
   aggregate. A refusal there fails the job.
8. **Processes.** `process Name, means: "…" do … end` in a context keeps one row per
   `key`, with attributes, a lifecycle (`moves`) and deadlines. `whenever Event, key:
   expression` is a step: its job inserts the row when absent, locks it and runs the block
   on it. A step changes at most one aggregate; its own row does not count. A process may
   follow another context's events outside a border, which draws an event edge, and takes
   `renamed_from:` as a projection does.
9. **Deadlines.** `deadline name, after: span do … end` in a process: `arm name` sets
   `<name>_due` and enqueues a job for that time, `arm name, after: other` uses another
   span, and `disarm name` clears it. The job runs the block only when no arming or
   disarming came after its own, acting as `deadline <Process>.<name>`.
10. **Units of work and checks.** A handler's projection and process rows live in a unit
    of work on its fiber and are saved when it returns. The whole-program checks run at the
    first `find?`, dispatch or job as well as at `SweetTalk.boot`.
11. **Database checks** (amends decision 2). An integer value's bounds and a string
    value's `length:` are also SugarORM `check` constraints on every column that stores
    the value, a composite's part columns included: `check_<table>_<column>` for bounds,
    and `check_<table>_<column>_length_<lo>_<hi>` for a length (`length_from_<lo>` or
    `length_to_<hi>` when one end is open), so a changed length is a new constraint.
    Such bounds are integer literals. `database_check: false` keeps a value's bounds in
    Crystal only, where they may name a constant. A pattern is checked in Crystal only.
    SweetTalk's changesets do not map these constraints: SweetTalk refuses first, so a
    violation from its own write raises `SugarORM::CheckViolation`. Any other bound, a
    constraint name over PostgreSQL's 63 bytes, and two declarations whose names give one
    table do not compile.

## Reasons

- One aggregate per transaction extends to services, compensations and process steps.
  A process's row is its own state, as a projection's is, so a step may change it and one
  aggregate.
- Deadlines use `run_at` and an arming counter because Cold Brew cannot cancel a job: a
  job that finds a newer arming does nothing.
- SugarORM's codecs store a value only as numeric, `jsonb` or text, so integer values keep
  integer columns and string values text columns.
- One column per part keeps each part queryable, with its own `CHECK` constraint.
- A `CHECK` holds for every writer. `Rows`, SQL backfills and other services skip
  SweetTalk's constructors; without it, their bad row fails at its next load, far from the
  write and as a refusal. A tightened bound stops the migration that validates it
  ([ADR 0008](0008-branch-and-diff-migrations.md)) instead of a later read. A range or a
  length is evaluated on the written row alone, with no reads, and `database_check:
  false` serves a table whose writes cannot spare it.
- Removing by a timestamp keeps every reference valid: an order line still names its tea,
  and a projection still keys its rows by it.
- `acting` keeps call sites unchanged: no command takes an actor argument, yet every event
  and every job that follows it knows who acted.
- A compensation is the policy's own answer to a refusal. Without it, a parcel dispatched
  for a cancelled order left Ordering's job failed.

Rejected:

- **A composite stored as one `jsonb` column.** Its parts could not be compared or
  constrained in SQL.
- **An explicit `by:` argument on every command.** Every caller would pass it, and a
  policy would have to pass it on.
- **Deleting rows.** References to the aggregate would dangle.
- **Patterns as `CHECK` constraints.** PostgreSQL reads regular expressions differently
  from Crystal: it refuses `\z`, which `Email` uses.
- **Leaving a non-literal bound out of the database unannounced.** A reader of the value
  could not tell which bounds the database holds.
- **Deferred:** correlation and causation ids linking a command to its events and jobs.
