# ADR 0056: SweetTalk reached events and pinned references

Date: 2026-11-07

Status: accepted. Amends [ADR 0048](0048-sweettalk-event-log.md) decision 3 and
[ADR 0030](0030-sweettalk-domain-language.md) decision 4.

## Context

An audit that asks "what did this event lead to" read each context's log by hand, joining on
`cause_id` across tables. A journal that must show the rules it was sealed under read the
rules as they are now, so a repricing changed a sealed journal's meaning; the application
copied the rules into the journal by hand (#263).

## Decision

1. **`Books.reached(event)` walks the logs forward by cause.** It returns a
   `SweetTalk::Reached` whose `events` are every event that followed from *event*, oldest
   first, as `SweetTalk::Event`, and whose `by_subject` groups them by `{"Shop::Ordering::Order",
   7}`, or `{"Shop::Ordering", nil}` for a context's event, each group in order. The walk is
   breadth first: the events whose `cause_id` is *event*'s id, then those caused by those,
   across every context that keeps a log, until a round finds no new event. It orders by
   `occurred_at`, the context's stored name and the log row's id, excludes *event*, and keeps
   an event once though two sharers log a kernel's.
2. **Where it ends.** The walk passes only through logged events: an event of a context
   without a log, or one a retention window pruned, ends its chain. A tenanted log reads the
   bound tenant's rows, and raises `SugarORM::Tenancy::Missing` when none is bound, as
   `logged` does. `reached` of an event the context's log does not keep raises
   `ArgumentError`, as `logged` does.
3. **The precondition is the cause.** Every event emitted while a handler, a compensation,
   a deadline or a process step runs carries that event's id as its cause. A command, a
   service or a unit called outside a handler starts a chain.
4. **`has rules : Setup::Rules, pinned_at: :finalized` copies the reference when the state
   is entered.** `pinned_at:` takes a state, in an aggregate, on a reference to another
   aggregate. When a mover enters the state the aggregate stores the referenced aggregate as
   JSON in `<name>_pinned`: its id, its state, and every attribute, entity lists included.
   `pinned_rules` reads it as a read-only copy, nil before the state is entered. The state
   must be one of the aggregate's `moves`, and not the first, which no mover enters.
5. **A copy is read only.** A command on a pinned copy raises `SweetTalk::Boundary`, "Rules 7
   is a pinned copy, read only: find Rules 7 to change it". An attribute a copy lacks, one
   the aggregate gained after the pin, is nil when optional, its default when it has one, and
   otherwise raises `ArgumentError`: make it optional or give it a default.

## Reasons

- The log already holds the cause of every event, written in the transaction that made it;
  the walk is the join an application wrote by hand, once.
- A reference names a row that changes; a document that must stay true says what the row
  was. A copy taken in the mover's own transaction is exact, where a copy taken by a handler
  would read a later row.

Rejected:

- **Following the aggregate's `flow_id`.** A flow groups everything one command started,
  including unrelated events; the cause says which led to which.
- **Pinning at creation.** The state is where the fact becomes true; a draft changes.
- **A pinned copy that can change.** It would stop being what the aggregate said.
