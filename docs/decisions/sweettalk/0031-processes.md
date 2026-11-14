# ADR 0031: A process keeps one row per key, and its steps, compensations and deadlines are Cold Brew jobs

Date: 2026-10-09

Status: accepted.

## Context

A command changes one aggregate, and a policy reacts to one event. A domain also needs workflows that span aggregates over days and undo their work when a step is refused: tins held for an order until its parcel leaves, and given back when the order is cancelled or the parcel is late. Such a workflow needs state of its own, a timer that survives a restart, and an answer when a handler is refused. The words are on the website at `site#c-sweettalk-processes`.

## Decision

1. **A process is a workflow declared in a context, with one stored row per key.** The row holds the workflow's state: attributes, a lifecycle and deadlines. A process is a word of the domain like an aggregate: it has a meaning, it can be renamed without moving its data, and it declares queries over its rows.
2. **The key is the row's identity, and a row starts from its key alone.** Every other attribute is optional or has a default, because the first event for a key creates the row with nothing else known. A process declares no uniqueness, index or check of its own: the key is the only identity it has.
3. **A step is an event handler with a key, run as a Cold Brew job on the locked row.** The job creates the row when it is absent, locks it, runs the block and saves the row. A step is queued, retried and attributed as any other event handler is ([ADR 0041](0041-events.md)).
4. **A step changes at most one aggregate, or runs one unit; its own row does not count.** The limit is the one a service has ([ADR 0046](0046-transactions.md)). A process declares no unit of its own.
5. **A process may follow another context's events without a border.** Doing so draws an event edge on the context map ([ADR 0036](0036-strategic-design.md)).
6. **A compensation answers a refused handler.** It is declared beside the handler it answers, in a context, a border or a process. It runs after the handler's work has rolled back, in a transaction of its own, with the handler's arguments and the refusal. It is held to the same limit as a step, and a refusal inside it fails the job.
7. **A deadline is a job scheduled for a time, and an arming counter decides whether it still runs.** A step arms or disarms a deadline on its row. The job runs its block only when no arming or disarming came after its own.
8. **A deadline's block is one handling, with an actor of its own.** It is held to the same limit as a step and runs in the tenant that armed it. It acts under the deadline's name, not as a user, and an event it emits has as its cause the event whose step armed it.

## Reasons

- One aggregate per transaction holds for process steps, compensations and deadlines as it does for commands and services. A process's row is its own state, as a projection's is, so a step may change it and one aggregate.
- A deadline uses a scheduled job and an arming counter because Cold Brew cannot cancel a job. A job that finds a newer arming does nothing.
- A compensation is the policy's own answer to a refusal. Without it, a parcel dispatched for a cancelled order left Ordering's job failed.
