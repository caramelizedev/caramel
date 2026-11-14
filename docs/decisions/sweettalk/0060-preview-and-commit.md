# ADR 0060: SweetTalk previews a change by running its body dry, and commits it by running the body again and comparing fingerprints

Date: 2026-11-07

Status: accepted.

## Context

A person often must see what a change would record before it records it, and the world can move between the screen and the click. An application kept a second code path for that: compute what would happen, hash it, and check the hash at commit. The second path could drift from the real one, and nothing proved they agreed.

## Decision

The rules an application relies on are stated on the website ([site.html](../../../website/source/site.html)), chiefly in `site#c-sweettalk-preview` of its Domain-Driven Design guide, and in the doc comments of [src/caramel/sweet_talk/preview.cr](../../../src/caramel/sweet_talk/preview.cr). This record states what was chosen. Commands, units and the ordered lock are [ADR 0046](0046-transactions.md)'s.

1. **`SweetTalk.preview { … }` runs the body dry.** It opens `SugarORM::Repo.transaction`, runs the block with the commit's locks, collects what it dispatches, reads the after-state of every aggregate a command loaded or made, and always rolls back. Event log rows, job rows, `pg_notify`, the operation claim of a unit that runs once and every row roll back with it, and every aggregate instance a command loaded or saved then reloads what is stored. A refusal raised by the body returns a preview with its sentence alone. It answers a `SweetTalk::Preview::Of(T)`, a `Preview` whose `value` is what the block returned, nil when the body was refused. A preview or commit inside another raises `SweetTalk::Boundary` (`SweetTalk.preview`, `site#c-sweettalk-preview`).
2. **A `Preview` shows the run.** It lists the events in dispatch order, each aggregate the run changed before and after, the warnings that held, the blockers, the sentence a commit would be refused with, and a summary grouped by aggregate and what happened. `to_json` serves tooling and leaves out `value`. Each reader and its order are in `site#c-sweettalk-preview` and the doc comments of `SweetTalk::Preview`.
3. **The canonical form leaves out instants and names new rows.** An event is its class, its subject and its fields. A row is its class, its subject, its state, whether it is removed and every attribute. An id of a row the run made, an aggregate's or an entity's, reads as `new Receipt #1`, numbered per type in the order the run made them; any other id is its number or its UUID. A `Time` reads as `"time"`. Event ids, `occurred_at`, the actor, the cause, the flow and row timestamps are left out. The event, aggregate and entity macros generate each packer from the declared types.
4. **The fingerprint covers events, rows, warnings and the refusal.** It is SHA-256 over the canonical events, the after-state of every row the run touched, the warnings and the refusal. The value and the blockers after the first stay out. `SweetTalk::Fingerprint` is a contract field value of `String`, by the field-value protocol of [ADR 0003](../0003-routing-and-ingress.md), and a form carries it in a hidden field; its grammar and its field error are in `site#c-sweettalk-preview` and `SweetTalk::Fingerprint`.
5. **`SweetTalk.commit(expected) { … }` re-runs and compares.** It runs the block in one transaction, builds the same fingerprint before the transaction ends, and raises `SweetTalk::Stale` carrying the fresh preview when it differs. Everything rolls back, and every aggregate instance the run touched reloads. A refusal at commit is raised as the refusal. It returns the block's value (`SweetTalk.commit`).
6. **A value not yet known is domain state.** A body that would record another number of events at commit is stale, as any other difference is.
7. **`Stale` is a refusal, and answers 422.** `SweetTalk::Stale` is a `SweetTalk::Refusal`. An action that does not rescue it answers through `render_stale(contract, stale)`, which an action overrides to show its form again with the fresh preview's fingerprint; what each client gets is [ADR 0033](0033-framework-boundary.md)'s.
8. **Approvals stay in applications.** An application that needs a second person stores that person's fingerprint on its own aggregate.
9. **`warn "…" { … }` in a unit confirms.** It runs after the body with the unit's `never` and `always` lines. When its block is true, a preview or commit keeps the sentence, which enters the fingerprint, and a plain call is refused with it. `assures:` on a `warn` does not compile.
10. **A unit's failing lines are blockers in a preview.** In a dry run a unit takes the same locks and runs the same body and lines, and runs every `never` and `always` line; each that fails adds its sentence to `blockers`, once, and the next line runs, so the preview keeps the run's events and changes beside them. Once the run holds a blocker, a line whose block raises is skipped. `refusal` is the body's refusal, or the first blocker. A commit and a plain call refuse with the first line that fails; no fingerprint confirms a blocker.
11. **Outside systems stay out of a dry-runnable body.** A command, a factory or a unit body that names a module declared by `border …, outside:` ([ADR 0036](0036-strategic-design.md)) does not compile, at the line that names it. While a preview runs, `Caramel::Outbound` raises `Caramel::Outbound::Refused`.

## Reasons

- One body is run twice, so the screen and the record cannot drift: the compare covers the code that writes.
- The compare runs inside the commit's transaction, so a stale commit writes nothing.
- A preview takes the commit's locks because the body stays one body; a dry run that read a snapshot instead would need a second path for its reads.
- After-state catches a command that emits nothing, such as a price change, without a revision counter that every write would bump.
- Instants and new ids differ on every run; left in, two previews of one change would never agree. Placeholders keep the ids a run made off the client and leave no gaps.
- The warning's sentence in the fingerprint is the confirmation: a person who saw it sent it back.
- A refusal is the domain's answer to a valid request, so `Stale` answers 422 as every refusal does ([ADR 0033](0033-framework-boundary.md)); one status keeps a client's handling to one shape.
- A call to an outside system cannot be rolled back, and it would hold the row locks while it waits. The text check names the line; the run-time refusal catches what text misses: an alias, or a method defined outside the context.
- Packers generated from declared types need no run-time reflection.
- A person reviewing a change sees every rule it breaks beside its figures, and cannot waive one: the commit refuses at the first. A line after a failed one may read what that one guards; the commit never reaches it, so the preview skips its raise.
- The block's value carries what a unit worked out on the way, such as a calculation's result ([ADR 0035](0035-reads-and-rules.md)), typed and without a new word. A subclass of `Preview` keeps every caller of `Preview` compiling.
- A screen that refreshes on every change does not preview, since each run takes the commit's locks: it loads without a lock and calls the calculation the unit's body calls, so the two agree.
- **Rejected: events alone in the fingerprint.** A silent command would commit unseen.
- **Rejected: the before-state of locked rows.** A write that leaves the outcome alone would make a preview stale.
- **Rejected: ids allocated at preview with `OVERRIDING SYSTEM VALUE`.** They reach the client and leave a gap for every abandoned preview.
- **Rejected: refusing to preview an unknown, or deferring it.** The domain already models a value not yet known as state.
- **Rejected: `warn` as advice only.** An application's confirmations block until a person agrees.
- **Rejected: a preview that skips `FOR UPDATE`.** Two paths again.
- **Rejected: 409 for `Stale`.** It is a refusal of a valid request.
- **Rejected: a framework `approval` word.** One application needs it; a second will say what it must hold.
- **Rejected: a `now` word for the clock.** Instants stay out of the canonical form instead.
- **Rejected: a `shows:` plan declared by a unit.** The block's value and a calculation carry it.
- **Rejected: the value in the fingerprint.** A figure a person must accept is a `warn` line, which the fingerprint covers.
- **Rejected: a `block` word beside `warn`.** A `never` already holds and cannot be waived; a second word would differ only in a preview.
- **Rejected: `preview` answering `{preview, value}`.** Every caller's type would change without a release that warns first.
- **Rejected: every blocker in the fingerprint.** A blocked preview never commits, and an unchanged canonical form keeps the fingerprint of every preview with no failing line across the upgrade.
