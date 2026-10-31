# ADR 0051: SweetTalk event log replay, retention and older events

Date: 2026-10-31

Status: accepted. Amends [ADR 0048](0048-sweettalk-event-log.md) decisions 1, 3 and 4.

## Context

ADR 0048 keeps a context's events in `<context>_events` and rebuilds a projection from them.
Its rebuild refused while a job of the projection's handlers was queued or running, but
checked once: an event that committed after the check was replayed by the rebuild and
applied again by its own job, and a job running beside the rebuild could write rows the
rebuild then counted. A busy application could not rebuild at all. `SweetTalk.prune_events`
let a schedule delete rows, and a later rebuild replayed what was left without saying so.
And a row logged, or a job queued, before an event gained a required field could not be
read: loading it raised on the missing key.

## Decision

1. **A rebuild leaves an event to the job that still has to apply it.**
   `SweetTalk.rebuild(Invoicing::Owed)` runs in one transaction under
   `pg_advisory_xact_lock` on the projection's table, deletes its rows and replays the log
   by id, as before, but refuses no queue. For each page it reads the jobs of the
   projection's handlers, and of the handlers each says `after:`, that carry one of the
   page's events and are neither finished nor failed, under every name `renamed_from:`
   gives them. It does not replay an event such a job carries, nor an element of `each:`
   whose job is among them: that job applies it once the rebuild commits. It replays an
   event whose job finished, failed or was pruned with its partition. Every job of a
   projection's handler takes `pg_advisory_xact_lock_shared` on the same key before its
   handler runs, so none runs while its projection rebuilds, and a rebuild waits for those
   that run. A log row commits with its jobs, a predecessor's finish with its followers'
   enqueue, and no handler job of the projection finishes during the rebuild, so each
   event is applied once. A failed job of the projection that an operator retries after
   the rebuild applies its event a second time, since the rebuild replayed it: discard
   such a job instead.
2. **`SweetTalk.rebuild` returns `SweetTalk::Rebuilt`:** `replayed`, the logged events the
   handlers ran for; `deferred`, the events left to a queued job, in whole or for some
   elements; and `oldest`, when the oldest event the log holds occurred, nil for an empty
   log. A log turned on after a context's first events holds none of them; `oldest` says
   where it starts.
3. **`event_log:` says how long the log keeps an event.** `event_log: true` keeps every
   event. `event_log: 90.days`, or any whole number of days or weeks, keeps one that many
   days: the context registers `Caramel::ColdBrew.every(1.hour, "sweettalk:prune:<table>")`,
   which deletes the rows that occurred before then, 1,000 a statement, across every
   tenant, in Cold Brew's scheduler. Any other value does not compile.
   `SweetTalk.prune_events` is removed. `SweetTalk.rebuild` of a projection whose context
   keeps its events a number of days does not compile.
4. **`older:` gives a field to events stored without it.** `event Printed, number : String,
   till : String, older: {till: "front"}, means: "…"` reads `"front"` for `till` from a
   queued job or a logged row whose fields lack it; the value is evaluated each time such
   an event is loaded. A key the event does not declare or carry, an optional field, which
   reads nil already, or an `older:` that is not a named tuple does not compile; a value of
   another type fails with Crystal's own message. A stored event that lacks a required
   field without `older:` still raises when it is read.
5. **Checks.** `spec/sweet_talk/event_log_spec.cr` proves against PostgreSQL that a queued
   job's event is left to it and applied once, that a follower's waiting predecessor
   defers the event, that a failed job's event is replayed, that a projection's job waits
   for the rebuild lock, the scheduled prune and `older:`; `spec/sweet_talk_tenancy`
   proves an element of `each:` left to its job. The fixtures `rebuild_with_retention`,
   `event_log_span`, `older_not_tuple`, `older_unknown`, `older_optional` and `older_type`
   prove the refusals.

## Reasons

- **The queue already knows what is left to apply.** Commanded's Ecto projections keep a
  `last_seen_event_number` beside the read model, and Marten a high-water mark that waits
  for gaps in the sequence; both need a cursor per projection, written with every event. A
  queued SweetTalk job already names the event it will apply, and the log row commits with
  it, so asking the queue for each page is exact without a new table. The shared lock costs
  one statement per projection job.
- **Applying an event twice is the failure every lineage framework names.** Spatie's replay
  with `--from` warns that it "does not track which events have already been processed";
  refusing a busy queue, as ADR 0048 did, traded that for a rebuild nobody could run.
- **A rebuild runs only projections.** Spatie never calls reactors on replay and Axon's
  `@DisallowReplay` keeps side effects out; a rebuild still enqueues nothing, so policies
  and processes act on the world once.
- **Retention is a property of the context, so the compiler knows when a rebuild cannot be
  complete.** Carbonite purges only what every outbox has passed, and EventStore refuses
  deletes unless a setting allows them; here the declaration is the setting. A horizon
  recorded at run time would find out late what the declaration already says. Days and
  weeks, as literals, because a log is kept for audits measured in days and a literal can
  be checked.
- **A default per field is the smallest thing that keeps old rows readable.** Spatie keeps
  an `event_version` and Axon chains upcasters by revision; Verbs shipped without either
  and its maintainers are still deciding. A SweetTalk event changes by gaining fields, which
  a default covers without a column; a field whose type changes is a new event, and a new
  name is `renamed_from:`.
- **One lock key per table.** A rebuild in one tenant holds that projection's jobs in every
  tenant back while it runs. A rebuild is rare and short, and one key keeps the lock the
  same with and without tenancy.

Rejected:

- **A cursor table per projection.** A write on every event and a second truth beside the
  queue.
- **Refusing at run time after a prune, from a recorded horizon.** It finds out at run time
  what the declaration says at compile time.
- **A CHECK on the log's fields.** It would stop an old binary's rows during a deploy and
  says nothing about queued jobs.
