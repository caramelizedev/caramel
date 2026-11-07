# ADR 0053: SweetTalk create announces Created

Date: 2026-11-07

Status: accepted. Amends [ADR 0031](0031-sweettalk-services-processes-and-richer-values.md)
decision 4, [ADR 0041](0041-sweettalk-events-that-carry-attributes.md) (the rejected
"Carrying every attribute by default") and [ADR 0048](0048-sweettalk-event-log.md)
decision 1.

## Context

A factory emits the event that says what was made, so a policy follows it and an event log
keeps it. `create` emitted nothing: an aggregate made with `create` was invisible to every
`whenever`, to `SweetTalk.rebuild` and to an audit, and the only way to see it was to read
its table (#265).

## Decision

1. **`create` announces `Created`.** An aggregate without a factory has an event `Created`
   on `sweettalk.<context>.<aggregate>.created` that carries every attribute, in
   declaration order, with the types `carries:` gives them: a reference is `Agg::Id`, a
   record `RecordId(Agg)`, an optional attribute optional. An attribute named like the
   metadata (`event_id`, `occurred_at`, `actor`, `cause_id`, `flow_id`, `<aggregate>_id`)
   is left out. The glossary lists it, meaning "<Aggregate> was created".
2. **The same transaction as a factory.** `create` checks the invariants, inserts the root
   and its entities, emits `Created` and dispatches it in one transaction, as a factory
   does, with one flow, and the open handling or unit remembers the aggregate as the one
   it changed. A `create` that a `never` refuses emits nothing.
3. **A declared `Created` is the one `create` emits.** `event Created, carries: [member],
   means: "…"` carries those attributes only. A declared `Created` with fields of its own
   fails compilation: `create` has nothing to give them.
4. **The channel is checked.** A `Created` channel past PostgreSQL's 63 characters, or 42
   with `caramel/tenancy`, fails compilation and names the choice: a shorter name, or a
   factory, which replaces `create` and `Created`.
5. **A factory is unchanged.** An aggregate with a factory has no `create` and no
   generated `Created`.

## Reasons

- A fact that something exists is the first fact a policy needs; leaving it to every
  aggregate's author to declare and emit meant most did not.
- Creation is the one change that makes every attribute true at once, so carrying all of
  them is the fact, and `carries:` listing each would restate the aggregate.
- Reusing the factory's making keeps one path for check, save and dispatch.

Rejected:

- **An opt-in `emits_created` word.** A second way to say what `create` already does,
  that an aggregate forgets.
- **Shortening the generated channel.** A channel that differs from the aggregate's other
  events breaks the `sweettalk.<context>.<aggregate>.<event>` shape every reader relies on.
