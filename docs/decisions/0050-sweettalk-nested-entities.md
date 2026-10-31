# ADR 0050: SweetTalk nested entities

Date: 2026-10-31

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 4,
[ADR 0031](0031-sweettalk-services-processes-and-richer-values.md) decision 3 and
[ADR 0045](0045-sweettalk-database-constraints.md) decision 5.

## Context

An entity could hold no entities: a slip with its marks, a line with its remarks, had to
flatten the inner list onto the aggregate and key each inner row by the outer one's
number by hand, which an aggregate's invariants and events could not see as one thing
(#250, after #167).

## Decision

1. **`entity` is a word of entities too.** `entity Mark, means: "…" do … end` inside an
   entity declares an entity it holds, and `has marks : Array(Mark)` stores the list, at
   any depth. Its table is `<parent table singular>_<entity>` pluralised,
   `counter_batch_slip_marks` for `Batch::Slip::Mark`, and its key to its parent is
   `<parent stored name>_id`, `slip_id`, composite with the tenant column in a tenanted
   context as every `belongs_to` to a tenanted row is.
2. **Loading is one statement per list per level.** `find`, `find?`, `all` and every query
   read the roots, then each list of entities, then each list under those for every row
   of the level at once, by the parent's id, and none for an empty level; entities come
   back by id. `entities: false` loads no level.
3. **Saving and dropping go children first.** A save deletes the rows each list was loaded
   with and no longer holds before it writes, the rows under them first, one `DELETE` per
   list per level through `IN (SELECT …)` on the dropped rows; then it writes the parent
   only when a column changed and saves each kept entity in turn. An entity moved to
   another parent is inserted anew with its own entities.
4. **Checks and facts recurse.** A command checks every `never` and `always` of the
   aggregate, then of each entity at every depth, before it saves; an event that carries
   an entity carries its lists, each entity with the id its row got.
5. **`unique` holds within the parent.** An entity's unique index leads with its parent's
   column, so two slips may each hold a mark with the same note.
6. **Names PostgreSQL would truncate do not compile.** A table name or an entity's key
   name `fk_<table>_<parent>_id` over 63 bytes is refused with the name, at every kind
   and depth, because PostgreSQL truncates silently and `frappe db diff` would then plan
   the same change on every run.
7. **`sums` and `groups` stay first-level.** `of:` names an attribute of the aggregate or
   of an entity it holds directly ([ADR 0049](0049-sweettalk-sums-and-groups.md)).

## Reasons

- A list inside an entity is the same shape as a list inside an aggregate, so it takes the
  same word, the same table naming and the same load, save and drop rules, applied once
  more per level.
- Deleting children first with `IN (SELECT …)` keeps one statement per list per level
  whatever the number of rows, and lets the foreign keys stay as they are.
- A silently truncated name is a defect found only when the diff never settles; refusing
  it at compile time names the fix.

Rejected:

- **`ON DELETE CASCADE` on the child key.** It changes the foreign keys existing
  applications have migrated, and hides the deletes from the statement count a spec
  reads, so a regression in what a save drops would pass unseen.
- **A JSON column of children.** It loses each entity's id, its key to its parent, and its
  constraints, and an event could not carry an entity by id.
