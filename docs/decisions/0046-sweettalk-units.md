# ADR 0046: SweetTalk units

Date: 2026-10-28

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 5 and
[ADR 0031](0031-sweettalk-services-processes-and-richer-values.md) decisions 5, 7, 8 and
10.

## Context

A command changes one aggregate, and a handler, service or process step changes one. Two
aggregates that must change together, such as a journal and the positions it posts, have
one seam: two commands called in turn inside one `SugarORM::Repo.transaction`, each a
savepoint. The seam is supported, but it is unnamed, takes each row's lock in the order the
code happens to call it, so two callers can deadlock, and checks the invariants of each
aggregate alone, so no rule can span the set. An application that builds its financial
layer on it writes its own `Books.unit` around the seam, with hold commands that lock each
aggregate first.

## Decision

1. **`unit` is a declared word.** `unit post(journal : Journal::Id, segments :
   Array(Segment::Id)), changes: [Journal, Position, Segment], locks: [journal, segments],
   returns: Nil, means: "…" do … end` in a context declares `Ledger.post`: a glossary entry
   with kind "unit" and a `domain` span named `Ledger.post`. `changes:` lists the aggregates
   its commands may change, declared before it; `locks:` names the arguments whose rows it
   locks first, each an id, an aggregate or an array of either; `returns:` defaults to
   `Nil`. A `never` or `always` line in its body is a rule over the set, run after the body.
   A unit without `means:`, with `changes:` that is not a list of aggregates declared before
   it, or with `locks:` naming anything but its arguments does not compile, nor does `unit`
   in an aggregate, an entity, a projection, a process or a kernel. `publishes` may name a
   unit as it names a service.
2. **A unit is one transaction, locks first.** It runs in `SugarORM::Repo.transaction`: it
   locks the rows `locks:` names, runs the body, runs its `never` and `always` lines, and
   commits. Each command inside it is a savepoint that dispatches its events as it does
   today; the unit pins one flow for them. A refusal, a boundary or any other error rolls
   the whole unit back, every aggregate instance its commands touched reloads what is
   stored, and the error goes on.
3. **`SweetTalk.lock` is the ordered lock.** `SweetTalk.lock(*ids)` takes ids, aggregates
   and arrays of either, groups them by table and locks each table's rows in one statement,
   `WHERE removed_at IS NULL AND id = ANY($1) ORDER BY id FOR UPDATE`, through the
   aggregate's rows query, so the tenant predicate applies; the tables go in name order. An
   id with no live row raises `SweetTalk::Missing`. Outside a transaction it raises
   `ArgumentError`. It is re-entrant: a row locked twice is held once. A call after a unit's
   own is ordered within its own batch only. An entity's or a record's id is not lockable.
4. **A unit's commands keep to its list and its locks.** A command or a `create` on a type
   outside `changes:` raises `SweetTalk::Boundary`, naming the unit and its list. A command
   on an existing row of an allowed type that `lock` did not take raises `Boundary` with
   "lock it in locks:"; a row created inside the unit needs no lock. A command inside a
   command is refused as before.
5. **Where a unit may run** (amends ADR 0030 decision 5 and ADR 0031 decisions 5, 7 and 8).
   An action, plain code, a service, a policy, a compensation, a deadline and a process
   step may call a unit. Inside a command, a factory or another unit it raises `Boundary`.
   Inside a handler or a service it is allowed only while that handling has changed
   nothing, and then it is the handling's one change: a command or a second unit after it
   raises `Boundary` with the handling's own message. The fiber keeps one handling object,
   `SweetTalk::Handling`, with what it changed, an aggregate or a unit, in place of the
   remembered aggregate alone.
6. **Crossing rules are unchanged.** Naming another context's aggregate in `changes:`
   needs `follows:` or `shares:`, and the published and border rules the context macro and
   the context map already check apply to the unit's text. A central context's unit may not
   change a tenanted aggregate; that does not compile.
7. **The seam stays.** Two commands called in turn inside one `SugarORM::Repo.transaction`
   still commit and roll back together, and `spec/sweet_talk` keeps proving it.
8. **`SweetTalk::Unit` is the running unit** (amends ADR 0031 decision 10). The row batch of
   a projection's or a process's handler is `SweetTalk::Work`, on
   `Fiber#__sweettalk_work`, so the word is free for the declared unit.
9. **Checks.** Each refusal above has a fixture in `sweet-talk-compilation`, and
   `spec/sweet_talk/units_spec.cr` runs the shelf's units against PostgreSQL: two boxes
   committed and rolled back together with both instances reloaded, a set rule refused, a
   type outside `changes:` and an unlocked row refused, a created row unlocked, two
   connections running one unit on the same boxes in opposite order, a unit as a service's
   one change, a unit refused inside a command and inside a unit, and `lock` refused outside
   a transaction.

## Reasons

- A declared word names the seam: the glossary lists what changes together, and the
  context map's text checks read `changes:` like any other naming.
- Locks taken first, by table then id, in one statement per table, give every caller one
  order whatever its arguments' order, so two units on the same rows wait instead of
  deadlocking; `ORDER BY id FOR UPDATE` locks rows as PostgreSQL returns them.
- Listing `changes:` keeps the unit as narrow as a command: a command on a type the unit
  did not declare is a stray write, and a command on a row it did not lock would take that
  lock late, after the body already read the row.
- A set rule after the body runs over the aggregates as the commands left them, within the
  same transaction, which no single aggregate's `never` can see.
- Reloading every touched instance after a rollback keeps the rule ADR 0030 set for one
  command: inside savepoints, only the database is certainly right.
- A unit counts as a handling's one change because it is one: letting a service run a unit
  and a command would make the service the seam again, without its list or its locks.
- Refusing a unit inside a command keeps a command's transaction its aggregate's own, and
  inside a unit keeps one list and one lock order per transaction.
- Renaming the row batch costs one internal word; a public `unit` beside a private `Unit`
  that meant something else would mislead every reader of the runtime.

Rejected:

- **Locking lazily, as each command runs.** It is the seam as it is: the order follows the
  code, and two callers deadlock.
- **Advisory locks.** They would not cover the row locks the commands take anyway, and
  would hold past the rows.
- **A unit inside a command.** The command's row lock would be held while the unit takes
  others, in the command's order.
- **Taking `changes:` from the body.** A receiver's type is unknown when a macro expands;
  the list is the author's statement, checked at run time as the one-aggregate rule is.
- **Keeping `SweetTalk::Unit` for the row batch.** The declared word would then have no
  class of its own, or a misleading one.
