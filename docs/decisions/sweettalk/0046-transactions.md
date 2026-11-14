# ADR 0046: SweetTalk changes one aggregate per transaction, names the exception as a unit, and previews by running the body dry

Date: 2026-10-08

Status: accepted.

## Context

A domain changes state in transactions, and something must say what one transaction may change. The DDD Reference draws that line at the aggregate, yet some aggregates must change together. Applications wrapped commands in a plain transaction for that, which locked rows in the order the code ran and checked no rule across the set. They also kept their own claims tables so a retried request did not move money twice ([#261](https://github.com/caramelizedev/caramel/issues/261)), and a second code path to show a person what a change would record.

## Decision

1. **A command is one transaction on one aggregate, and so is a service.** A command locks the root's row. A refusal rolls it back, and the aggregate reloads what is stored. Reaching a second aggregate is an error, checked at run time.
2. **A refusal may name the field it is about, where the rule is written.**
3. **A unit is the declared word for changing several aggregates together.** It joins the glossary and declares the aggregates its commands may change and the arguments whose rows it locks. A command outside that list, or on a row the unit did not lock, is an error. Two commands in a plain transaction stay supported.
4. **A unit takes its row locks first, in one order.** It locks by table and then by id, whatever order the arguments came in.
5. **A unit states rules over the set, and fails as a whole.** Any error rolls it back, and every touched instance reloads what is stored.
6. **A unit is the one change of whatever calls it.** A service or a handler may run a unit only as its single change. A unit inside a command, a factory or another unit is an error.
7. **A unit may run once per operation key.** A repeat with the same arguments replays the first outcome; a repeat with other arguments is refused. The claim is a row in a derived table, written in the unit's own transaction and kept forever. A run that fails leaves no claim.
8. **A preview runs the real body dry.** It takes the commit's locks and always rolls back.
9. **A commit runs the body again and compares fingerprints.** A difference writes nothing and is a refusal that carries the fresh preview, answered as every refusal is ([ADR 0033](0033-framework-boundary.md)).
10. **The fingerprint covers events, the after-state of touched rows, warnings and the refusal.** It leaves out instants and names rows the run made by placeholder.
11. **A warning in a unit is a confirmation.** A plain call is refused with its sentence. Sending back a fingerprint that holds the sentence confirms it.
12. **A preview reports every failing rule as a blocker.** A commit refuses at the first, and no fingerprint confirms a blocker.
13. **Outside systems stay out of a body that can run dry.** A command, a factory or a unit body may not name an outside border ([ADR 0036](0036-strategic-design.md)), and outbound calls are refused while a preview runs.
14. **Approvals and unknown values stay in the domain.** An application that needs a second person stores that person's fingerprint on its own aggregate.
15. **Each command, factory, service and unit is a traced span that carries its name and no arguments or ids ([ADR 0027](../0027-crema.md)).**

## Reasons

- The DDD Reference governs transactions by aggregate boundaries. One aggregate per transaction keeps each lock and each invariant its aggregate's own.
- The guards run at run time because a call's receiver type is unknown when a macro expands. Rejected: taking a unit's list from its body.
- The row lock orders commands on one aggregate so each sees the last one's result, where a version column would fail the later one.
- Rejected: restoring an in-memory snapshot after a refusal. Inside savepoints, only the database is certainly right.
- Rejected: a refusal's field chosen by a rule's identity.
- A declared word names the seam: the glossary lists what changes together.
- Locks taken first in one order make two units on the same rows wait instead of deadlocking. Rejected: locking lazily as each command runs, which follows the code's order.
- Rejected: advisory locks. They would not cover the row locks the commands take anyway, and would hold past the rows.
- A command on an undeclared type is a stray write, and one on an unlocked row would take its lock late, after the body read the row.
- A unit counts as a handling's one change because it is one. A service that ran a unit and a command would be the seam again, without its list or its locks.
- Rejected: a unit inside a command. The command's row lock would be held while the unit takes others, in the command's order.
- Idempotency belongs where the state changes: the claim and the change commit together. Rejected: a hand-written claims table, the workaround this replaces.
- Rejected: a key that is the fingerprint. A client that retries with a changed field is a new request; the client's key says it is the same one.
- Rejected: pruning claims after a time. A late retry would run twice, and how long a key may come back is the client's contract.
- One body run twice cannot drift: the compare covers the code that writes.
- Rejected: a preview that skips the locks or reads a snapshot. It needs a second path.
- After-state catches a command that emits nothing. Rejected: events alone, where a silent command commits unseen; and the before-state of locked rows, where a write that leaves the outcome alone makes a preview stale.
- Instants and new ids differ on every run. Rejected: ids allocated at preview, which reach the client and leave a gap for every abandoned preview.
- A stale commit is the domain's answer to a valid request. Rejected: 409; one status keeps a client's handling to one shape.
- Rejected: a warning as advice only. An application's confirmations block until a person agrees.
- A reviewer sees every rule a change breaks and cannot waive one. Rejected: a separate blocking word, which would differ from an ordinary rule only in a preview.
- A call to an outside system cannot be rolled back, and it would hold the row locks while it waits.
- Rejected: refusing to preview an unknown value, which the domain already models as state.
- Rejected: a framework word for approvals. One application needs it; a second will say what it must hold.
- A span names the command a trace ran, which its SQL alone does not.
