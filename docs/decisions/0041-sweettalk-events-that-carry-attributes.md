# ADR 0041: SweetTalk events that carry attributes

Date: 2026-10-24

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 6.

## Context

An event that tells what a transfer was when it settled declared each of the aggregate's
fields with its type, and every command that emitted it passed each field again. An
event of 17 fields was written as 17 declarations and 17 `name: name` arguments, and the
two lists were checked only when something emitted the event.

## Decision

1. **`event Settled, carries: [kind, amount, owner], means: "…"`** declares one field for
   each attribute or derived value named, of that attribute's type, in the order given. A
   reference is carried as its id, `Owner::Id?` for an optional one. `carries:` takes
   names written as words or symbols; it can follow explicit fields, as in
   `event Undone, note : String, carries: [owner], means: "…"`.
2. **`emit Settled` reads those fields from the aggregate as it is when `emit` runs.** A
   command that changes an attribute after `emit` does not change the event. A command
   cannot give a carried field, as in `emit Settled, owner: nil`: that does not compile,
   because the event would say what the aggregate does not hold. A field the event does not
   carry, declared beside `carries:`, is given as before.
3. **The event stays typed and checked at compile time.** A name that is not an attribute
   or a derived value declared above the event, a name twice, or one named like the
   event's metadata does not compile; the message lists what the aggregate has. A carried
   field is an ordinary field: it has a getter, is stored in the event's JSON and read
   back for a `whenever` as emitted, and `SWEETTALK_CARRIES` lists the names.
4. **`the` records its type**, so a derived value can be carried.
5. **A job that is already queued reads what was written, and an optional field that is
   not there is nil.** A field typed `T?` that a queued event lacks, because the event was
   emitted before the field existed, is read as nil. A required field that is missing still
   fails, as a queued job that lacks a field of its declaration cannot be run.

## Reasons

- The field's type and name were already written once on the attribute. Restating them in
  an event copies a declaration, and the copies drift. Carrying removes the copy and makes
  the coupling explicit, which is the trade-off below.
- Reading at `emit` time is what an explicit `kind: kind` read, so an event carries facts
  as they were, as ADR 0030 decision 6 says, and a handler never loads the aggregate.
- The list names the fields once, in the declaration that says what the event is, instead
  of in each command that raises it.
- A command may not give a carried field, because a carried field is the aggregate's, read
  when the event is emitted: an event that said `owner: nil` of an aggregate whose owner is
  set would be a fact the aggregate cannot show. An event that reports a change and needs
  the value before it declares a field of its own name, as `before_owner : Owner::Id?`.

**Trade-off: the event is a snapshot of the aggregate.**

`carries:` ties the event to the aggregate's attribute: its name, its type and what it
holds. An event is stored, as JSON, in the job that delivers it to the handlers, so:

- **Renaming or retyping a carried attribute changes the payload of jobs already queued.**
  A job queued under the old name lacks the new field, and one queued under the old type
  holds a value of the old type. Nothing fails when the aggregate is compiled; the job
  fails, or reads nil, when a worker runs it. This is a deliberate coupling: the event is
  the aggregate's own, and in exchange no declaration is repeated.
- **To rename safely**, keep the old field in the event for as long as jobs may still be
  queued: when `owner` becomes `account`, declare `the owner : Account::Id? = account` above
  the event, a derived value with the old name, and carry `[account, owner]`, so a job
  queued under either name reads. Drop the old name once the queue has drained. Or emit a
  new event for the new shape and keep handling the old event until its jobs are done.
  `renamed_from:` renames a stored table or event, not a carried field. An optional field
  that a queued job lacks reads as nil, so adding a carried optional attribute is safe.
- An event of 17 fields that are all the aggregate's is the case this serves. An event that
  should stay stable while the aggregate changes shape should declare its own fields.

Rejected:

- **`emit Settled, from: self` with fields chosen at the call.** Each command would say
  again which fields the event has, and two commands could say differently.
- **Carrying every attribute by default.** An event is a fact about one change; what it
  holds should be listed, and `carries:` lists it once.
- **Reading the aggregate in a handler.** ADR 0030 refuses it: a handler would read what
  is true now, not what happened.
