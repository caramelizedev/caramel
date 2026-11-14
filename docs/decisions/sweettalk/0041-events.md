# ADR 0041: A SweetTalk event carries its facts and leaves through Cold Brew in the command's transaction

Date: 2026-10-08

Status: accepted.

## Context

A domain event names something that happened, and other parts of the program react to it. It must reach its handlers without being lost or sent for a rolled-back change, and say who acted and what caused it. An event that existed only in its job rows left audits to a hand-written context and gave a later projection nothing to rebuild from ([#248](https://github.com/caramelizedev/caramel/issues/248), [#263](https://github.com/caramelizedev/caramel/issues/263), [#265](https://github.com/caramelizedev/caramel/issues/265)).

## Decision

1. **An event belongs to an aggregate or to a context, and only its owner emits it.** A context's own event is for a change no aggregate holds, and only a service emits it.
2. **An event holds its facts as they were when it was emitted, and no getter on it loads an aggregate.**
3. **`carries:` takes an event's fields from the aggregate by name.** They are read when `emit` runs, and a command cannot give one. An event that must stay stable while the aggregate changes shape declares its own fields.
4. **Every event records its id, when it occurred, who acted, what caused it and its flow, and its jobs carry them.** `SweetTalk.acting` names the actor around a block, so no command takes an actor. Each handler runs as its event's actor, and a retried job keeps the same event id.
5. **`create` announces `Created`, which carries every attribute.** An aggregate with a factory has neither; the factory's own event says what was made.
6. **The outbox: the command enqueues one Cold Brew job per handler, in its own transaction.** The enqueue commits or rolls back with the command ([ADR 0009](../0009-cold-brew.md)). No handler assumes another's work is saved.
7. **`after:` orders two handlers of one event: the predecessor's job enqueues its followers in the transaction that saves its work.** A refused or failed predecessor releases none.
8. **The queue stores a job's name, after its owner and its event, and a rename declares the old one.**
9. **A refusal or a boundary fails a job at once; any other error is retried.**
10. **A stored event is read as it was written, and a field added later declares a default for older events.** A field whose type changes is a new event.
11. **The notification carries the subject's id, never the fields.**
12. **A projection keeps one row per key, and a handler reads the row locked.**
13. **A context may keep its events in a log, written in the command's transaction; rows stay the truth.** The log is opt-in per context and append-only, and no aggregate is loaded from it. Each sharer of a kernel logs the kernel's events.
14. **A read of the log before a moment is what the program knew then.** An event is stamped when it is emitted, not when what it records took effect.
15. **Retention is declared on the context, as a literal number of days or weeks.** Rebuilding a projection of a context that prunes its log does not compile.
16. **A rebuild replays the log through the projection's own handlers, enqueues nothing, and leaves an event to the queued job that still has to apply it.** The queue is the cursor, so each event is applied once.
17. **`reached` walks the logs forward by cause.** An event that was not logged ends its chain.
18. **`pinned_at:` copies a referenced aggregate when a state is entered.** The copy is taken in the transaction of the command that enters the state, and it is read only.

## Reasons

- Enqueueing and logging in the command's transaction means an event is never lost or sent for a rolled-back change. A log written by a policy would be eventual and could disagree with the rows.
- An event records what happened. Rejected: reading the aggregate in a handler, which reads what is true at that moment.
- Rejected: policies inside the publishing command. A policy's refusal would reach the client after the first change had been kept.
- An attribute's name and type are already written once on the aggregate; restating them in the event copies a declaration, and the copies drift. Trade-off: a carrying event is coupled to the aggregate's attribute.
- Rejected: carrying every attribute by default. What an event holds should be listed; only creation makes every attribute true at once.
- That something exists is the first fact a policy needs; left to each author to declare and emit, most did not. Rejected: an opt-in `emits_created` word, which an aggregate forgets.
- `acting` keeps call sites unchanged. Rejected: a `by:` argument on every command, which every caller would pass. Rejected: ids in log lines only, because a queued event could not name its cause.
- A follower enqueued in the predecessor's transaction is atomic with the work it waits for. A worker-side wait would hold a fiber and cannot see another process.
- A default per field keeps old events readable: a SweetTalk event changes by gaining fields.
- A notification carries an id: fields could pass Cold Brew's payload limit, and the refused publish would roll the command back.
- Rejected: event sourcing. Loading an aggregate from its log changes every command's read and the model in which rows are the truth.
- Deferred: keeping one aggregate's events as its truth. It waits for a second application that needs it.
- Rejected: `SweetTalk.after_dispatch { }`. Every application would write a different log, and nothing could rebuild from it.
- Rejected: logging only what a projection follows. An audit needs every event, and a projection added later follows events nobody followed.
- A queued job already names the event it will apply, and its log row commits with it, so the queue is exact without a new table. Rejected: a cursor table per projection or a watermark, a second truth beside the queue. Rejected: refusing a rebuild while a job is queued, which a busy application could not run.
- Retention is a property of the context, so the compiler knows when a rebuild cannot be complete. Rejected: a horizon recorded at run time.
- The log already holds each event's cause, so `reached` is the join an application wrote by hand. Rejected: following the flow, which groups everything one command started.
- A reference names a row that changes; a document that must stay true says what the row was. Rejected: pinning at creation, because a draft changes. Rejected: a copy that can change, which stops being what the aggregate said.
