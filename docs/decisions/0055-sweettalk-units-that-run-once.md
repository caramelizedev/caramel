# ADR 0055: SweetTalk units that run once

Date: 2026-11-07

Status: accepted. Amends [ADR 0046](0046-sweettalk-units.md) decision 1 and the rejected
"claims table" of [ADR 0045](0045-sweettalk-database-constraints.md).

## Context

A client that retries a request must not move money twice. A unit that posted a transfer
ran again for each retry, and an application kept its own claims table, written in the
same transaction, with the fingerprint of the request and what it answered, one per unit
(#261).

## Decision

1. **`unit post(key : String, …), once_by: key` runs once per operation key.** `once_by:`
   names one argument, a `String` or a value that wraps `String`. The unit's name and that
   key are the operation.
2. **A repeat replays the first outcome.** The unit keeps a fingerprint of every other
   argument, as SHA-256 of the arguments packed as JSON in declaration order. A repeat
   with the same fingerprint skips the locks, the body and the rules and answers the first
   outcome: nil for a unit that returns `Nil`, otherwise what `returns:` unpacks from the
   stored JSON.
3. **A repeat with other arguments is refused.** `SweetTalk::Refusal` with the sentence
   `otherwise: "…"` gives, or "<Context>.<unit> already ran under this key with other
   arguments". `otherwise:` without `once_by:`, or as anything but text, does not compile.
4. **The table is derived.** A context with such a unit has `<context>_operations`,
   `Rows::Operations`: `unit`, `key`, `fingerprint`, `outcome` jsonb and `created_at`, with
   a unique index over `unit` and `key`, tenanted as the context's rows are, so each tenant
   has its own keys. `frappe db diff` creates it. A declaration whose table it would take
   does not compile.
5. **The claim is the first statement in the unit's transaction.** It is an insert in a
   savepoint. A key already claimed raises `UniqueViolation` or `Invalid`, which rolls back
   that insert alone and leads to reading the row. A concurrent first run holds the second
   on its uncommitted row, until it commits and the second replays it, or rolls back and the
   second runs.
6. **An error rolls the claim back with the unit.** A refusal or an error leaves no row, so
   a retry runs again. The outcome is written after the rules pass, in the same transaction.
7. **What a unit keeps must be plain.** The other arguments and the result hold ids, values
   and scalars: an aggregate in either does not compile, since a replay could not build it.
8. **Rows are kept forever.** Nothing prunes `<context>_operations`; a retention window
   would have to choose how long a key may come back, which is the client's contract.

## Reasons

- Idempotency belongs where the state changes: the claim and the change commit together, so
  there is no moment where one holds without the other.
- A fingerprint tells a retry from a new request that reused a key, which would otherwise
  be answered with the wrong outcome.
- A derived table named by the unit says which unit it guards, and follows the tenant.

Rejected:

- **A hand-written claims table.** The workaround this replaces.
- **A key that is the fingerprint.** A client that retries with a changed field is a new
  request; the client's key says it is the same one.
- **Pruning operations after a time.** It would turn a retry that arrives late into a
  second run.
