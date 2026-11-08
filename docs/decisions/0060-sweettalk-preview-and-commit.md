# ADR 0060: SweetTalk preview and commit

Date: 2026-11-07

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 6,
[ADR 0034](0034-sweettalk-at-the-web-boundary.md) decision 2,
[ADR 0036](0036-sweettalk-strategic-design.md) decision 4 and
[ADR 0046](0046-sweettalk-units.md) decision 2. Decision 3 is amended by
[ADR 0064](0064-uuidv7-identity.md).

## Context

A person often must see what a change would record before it records it, and the world
can move between the screen and the click. An application kept a second code path for
that: compute what would happen, hash it, and check the hash at commit. The second path
could drift from the real one, and nothing proved they agreed.

## Decision

1. **`SweetTalk.preview { … }` runs the body dry.** It opens `SugarORM::Repo.transaction`,
   runs the block with the commit's locks, collects what it dispatches, reads the
   after-state of every aggregate a command loaded or made, and always rolls back. Event
   log rows, job rows, `pg_notify`, a unit's operation claim
   ([ADR 0055](0055-sweettalk-units-that-run-once.md)) and every row roll back with it.
   Every aggregate instance a command loaded or saved then reloads what is stored. A
   refusal raised by the body returns a preview with its sentence alone; a unit's failing
   lines do not end the run (decision 11). It answers a `SweetTalk::Preview::Of(T)`, a
   `Preview` whose `value` is what the block returned, nil when the body was refused. A
   preview or commit inside another raises `SweetTalk::Boundary`.
2. **A `Preview` shows the run.** `events` lists each event in dispatch order with its
   subject and fields. `changes` lists each aggregate the run changed, before and after,
   in the order it was first touched; one made by the run has no before. `warnings` lists
   the unit's `warn` lines that held, `blockers` the sentences of its `never` and `always`
   lines that failed, in the order they ran, and `refusal` the sentence a commit would be
   refused with: the body's refusal, or the first blocker. `summary` groups by aggregate
   and what happened: removals and moves into a state no move leaves first, then each kind
   of event, then each change no event names. `to_json` serves tooling and leaves out
   `value`.
3. **The canonical form leaves out instants and names new rows.** An event is its class,
   its subject and its fields. A row is its class, its subject, its state, whether it is
   removed and every attribute. An id of a row the run made, an aggregate's or an
   entity's, reads as `new Receipt #1`, numbered per type in the order the run made them;
   any other id is its number or its UUID. A `Time` reads as `"time"`. Event ids,
   `occurred_at`, the actor, the cause, the flow and row timestamps are left out. The
   event, aggregate and entity macros generate each packer from the declared types.
4. **The fingerprint covers events, rows, warnings and the refusal.** It is SHA-256 over
   the canonical events, the after-state of every row the run touched, the warnings and
   the refusal. `SweetTalk::Fingerprint` is a contract field value of `String`
   ([ADR 0034](0034-sweettalk-at-the-web-boundary.md) decision 3): 64 lowercase hex
   digits, or the field's error "is not a preview's fingerprint". A form carries it in a
   hidden field. The value and the blockers after the first stay out.
5. **`SweetTalk.commit(expected) { … }` re-runs and compares.** It runs the block in one
   transaction, builds the same fingerprint before the transaction ends, and raises
   `SweetTalk::Stale` carrying the fresh preview when it differs. Everything rolls back, and
   every aggregate instance the run touched reloads. A refusal at commit is raised as the
   refusal. It returns the block's value.
6. **A value not yet known is domain state.** A body that would record another number of
   events at commit is stale, as any other difference is.
7. **`Stale` answers 422.** It is a `SweetTalk::Refusal`. The hook of ADR 0034 decision 2
   answers it through `render_stale(contract, stale)`, which a JSON client gets as the
   refusal's errors with the fresh preview under `preview`, and any other client as
   `render_refusal`. An action overrides `render_stale` to show its form again with the
   fresh preview's fingerprint.
8. **Approvals stay in applications.** An application that needs a second person stores
   that person's fingerprint on its own aggregate.
9. **`warn "…" { … }` in a unit confirms.** It runs after the body with the unit's `never`
   and `always` lines. When its block is true, a preview or commit keeps the sentence, which
   enters the fingerprint, and a plain call is refused with it. `assures:` on a `warn` does
   not compile.
10. **Outside systems stay out of a dry-runnable body** (amends ADR 0036 decision 4). A
   command, a factory or a unit body that names a module declared by `border …, outside:`
   does not compile, at the line that names it. While a preview runs,
   `Caramel::Outbound` raises `Caramel::Outbound::Refused`, which catches an alias or a
   method defined outside the context.
11. **A unit's failing lines are blockers in a preview** (amends
   [ADR 0046](0046-sweettalk-units.md) decision 2). In a dry run a unit runs every `never`
   and `always` line; each that fails adds its sentence to `blockers`, once, and the next
   line runs, so the preview keeps the run's events and changes beside them. Once the run
   holds a blocker, a line whose block raises is skipped. A commit and a plain call refuse
   with the first line that fails, as before; no fingerprint confirms a blocker.

## Reasons

- One body is run twice, so the screen and the record cannot drift: the compare covers
  the code that writes.
- The compare runs inside the commit's transaction, so a stale commit writes nothing.
- A preview takes the commit's locks because the body stays one body; a dry run that read
  a snapshot instead would need a second path for its reads.
- After-state catches a command that emits nothing, such as a price change, without a
  revision counter that every write would bump.
- Instants and new ids differ on every run; left in, two previews of one change would
  never agree. Placeholders keep the ids a run made off the client and leave no gaps.
- The warning's sentence in the fingerprint is the confirmation: a person who saw it sent
  it back.
- A refusal is the domain's answer to a valid request, so `Stale` answers 422 as ADR 0034
  answers refusals; one status keeps a client's handling to one shape.
- A call to an outside system cannot be rolled back, and it would hold the row locks while
  it waits. The text check names the line; the run-time refusal catches what text misses.
- Packers generated from declared types need no run-time reflection.
- A person reviewing a change sees every rule it breaks beside its figures, and cannot
  waive one: the commit refuses at the first. A line after a failed one may read what that
  one guards; the commit never reaches it, so the preview skips its raise.
- The block's value carries what a unit worked out on the way, such as a calculation's
  result ([ADR 0062](0062-sweettalk-calculations.md)), typed and without a new word. A
  subclass of `Preview` keeps every caller of `Preview` compiling.
- A screen that refreshes on every change does not preview, since each run takes the
  commit's locks: it loads without a lock and calls the calculation the unit's body calls,
  so the two agree.

Rejected:

- **Events alone in the fingerprint.** A silent command would commit unseen.
- **The before-state of locked rows.** A write that leaves the outcome alone would make a
  preview stale.
- **Ids allocated at preview with `OVERRIDING SYSTEM VALUE`.** They reach the client and
  leave a gap for every abandoned preview.
- **Refusing to preview an unknown, or deferring it.** The domain already models a value
  not yet known as state.
- **`warn` as advice only.** An application's confirmations block until a person agrees.
- **A preview that skips `FOR UPDATE`.** Two paths again.
- **409 for `Stale`.** It is a refusal of a valid request.
- **A framework `approval` word.** One application needs it; a second will say what it
  must hold.
- **A `now` word for the clock.** Instants stay out of the canonical form instead.
- **A `shows:` plan declared by a unit.** The block's value and a calculation carry it.
- **The value in the fingerprint.** A figure a person must accept is a `warn` line, which
  the fingerprint covers.
- **A `block` word beside `warn`.** A `never` already holds and cannot be waived; a second
  word would differ only in a preview.
- **`preview` answering `{preview, value}`.** Every caller's type would change without a
  release that warns first.
- **Every blocker in the fingerprint.** A blocked preview never commits, and an unchanged
  canonical form keeps every fingerprint a form holds across the upgrade.
