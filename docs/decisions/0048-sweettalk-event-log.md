# ADR 0048: SweetTalk event log

Date: 2026-10-28

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 6 and
[ADR 0041](0041-sweettalk-events-that-carry-attributes.md) decision 3. Decisions 1, 3 and 4
are amended by [ADR 0051](0051-sweettalk-event-log-replay-and-retention.md).

## Context

An event existed only as the job rows it was carried in, pruned with their partition after
seven days, and as a `pg_notify`. An audit written by a policy was eventual and retried, so
an application that had to explain its numbers kept a second, hand-written audit context
that could disagree with the events it followed. A projection added later started empty,
with nothing to rebuild it from. A policy that needed a read model's row waited for no one:
jobs start in declaration order and finish in any, so "run after Sales has saved" could not
be said (#248, split from #168).

## Decision

1. **`context Billing, event_log: true, means: "…"` keeps the context's events in
   `billing_events`.** `SweetTalk.dispatch` calls each context's generated
   `__sweettalk_log`, a no-op without the keyword, before it enqueues jobs; with the keyword
   it inserts one row for every event of the context, from an aggregate's command or a
   service's `emit`, and for every event of a kernel the context shares, on the current
   connection, so the row commits and rolls back with the command. A kernel takes no
   `event_log:`: its events are logged by each sharer that keeps a log, under the aggregate
   name `<kernel>_<aggregate>`. The keyword takes `true` only.
2. **The table is part of the derived schema.** `Billing::Rows::Events` is a SugarORM
   schema, so `frappe db diff` creates it and the spec harnesses migrate it. Columns: `id`
   bigint identity, `event_id` text unique, `aggregate` text (the aggregate's stored name,
   or the context's own for a service's event), `name` text (the stored event name, the
   `renamed_from:` original as the channel says it), `subject_id` bigint null, `occurred_at`
   timestamptz, `actor` text null, `cause_id` text null, `flow_id` text, `fields` jsonb
   through `SugarORM::JSONB(JSON::Any)`, and `created_at` alone: a row is never updated.
   Indexes: `(flow_id)`, `(cause_id)`, `(aggregate, subject_id, id)` and `(occurred_at)`.
   Under `caramel/tenancy` the schema declares the tenant as every table of the context
   does, so each tenant reads its own rows and a central context's log is shared. A
   declaration whose table would be `<context>_events` does not compile.
3. **`Billing.logged` reads typed events.** `Billing.logged(Invoiced, subject: id, since: t,
   limit: 100)` returns `Array(Invoiced)` built through the event's `__sweettalk_load` from
   the row's fields and metadata, oldest first and newest last, the first `limit` rows after
   `since:` by `occurred_at`; `subject:` takes an id or an `Int64`. `Billing.logged(subject:
   id)` returns every class as `Array(SweetTalk::Event)`, chosen by the row's aggregate and
   name; a row no event stores any more raises `ArgumentError`, naming `renamed_from:`, as
   does a class the log does not keep. `SweetTalk.prune_events(Billing, before: t, chunk:
   1000)` deletes the rows that occurred before `t`, `chunk` rows a statement until one
   comes back short, across every tenant, and returns the count; a context without the
   keyword does not compile. A `Caramel::ColdBrew.every` block is its retention.
4. **`SweetTalk.rebuild(Billing::Sales)` replays the log through the projection's own
   handlers.** In one transaction it takes `pg_advisory_xact_lock(LOCK_NAMESPACE,
   hashtext(table))` in Cold Brew's two-key namespace, counts `caramel_jobs` rows of the
   projection's job classes that are neither finished nor failed and refuses with a
   `SweetTalk::Refusal` naming them when any exists, deletes the projection's rows, pages the
   log by `id` and runs each followed event through the generated `__sweettalk_on_*`, one
   unit of work per event and one per element with `each:`, then returns the count. It
   enqueues nothing: a follower that says `after:` the projection is not released. Under
   tenancy it rebuilds the bound tenant's rows from the bound tenant's log. The macro refuses
   a projection whose context keeps no log, or that follows an event the log does not keep.
   A handler that reads present state replays against present state, and a rebuild covers
   only the events logged since the keyword was set.
5. **`whenever Order::Placed, after: Sales do … end` orders two handlers of one event.**
   `after:` names a projection, a process or a context that follows the same event.
   `dispatch` does not enqueue such a handler: the predecessor's job calls
   `SweetTalk.__sweettalk_release` once its body has run, inside the transaction that saves
   its work, and that enqueues each follower with the same subject, fields and metadata,
   one job per element when the follower takes `each:`. The whole-program check, at `macro
   finished`, resolves each handler's event and `after:` from the owner's scope outwards and
   refuses an owner that is not a projection, process or context, one that does not follow
   the event or follows it twice (in a border and outside it), a predecessor that takes
   `each:`, and a chain of `after:` that runs in a circle. A refused or permanently failed
   predecessor never releases its followers.
6. **A program without the keyword changes nothing.** No `_events` table, no row, no extra
   statement in `dispatch`; the existing specs run unchanged, and `after:` works without a
   log.
7. **Checks.** `spec/sweet_talk/event_log_spec.cr` on the billing desk and the tenant shop's
   examples prove the rows, the reader, pruning, the rebuild and its lock and refusal, the
   ordering and the absence of followers after a failed predecessor against PostgreSQL; the
   fixtures `after_not_following`, `after_cycle`, `after_each`, `rebuild_without_log` and
   `event_log_table_taken` prove the refusals.

## Reasons

- **In the command's transaction, or not at all.** A log written by a policy would be
  eventual and could disagree with the rows; one row inserted beside the job rows costs one
  statement and cannot be lost or sent for a rolled-back change.
- **Rows stay the truth.** The log serves audits, rebuilds and reads of what happened; no
  aggregate is loaded from it, so a context that never turns it on is untouched, and one
  that does keeps ADR 0030's model.
- **A kernel's events go to every sharer that logs.** A kernel's command may run from any
  sharer, or from an action; the log is the sharer's, kept so the sharer's projections can
  be rebuilt, and a projection following a kernel event needs every such event in its own
  context's log, whoever ran the command. The aggregate column leads with the kernel's
  name so a kernel's `Voucher` and the context's own cannot collide.
- **Stored names, not class names.** `aggregate` and `name` are what the channel stores, so
  `renamed_from:` keeps old rows readable as the job names and tables already are.
- **A rebuild refuses a busy queue.** A queued handler job would write once more what the
  replay wrote; a watermark would need every job to carry its log id. Refusing with the job
  names is cheap and exact, and the advisory lock keeps two rebuilds apart.
- **The predecessor enqueues its followers.** A worker-side wait would hold a fiber and
  cannot see a predecessor in another process; a follower enqueued in the predecessor's
  transaction is atomic with the work it waits for, and is never enqueued when that work
  rolls back, which is also the consequence stated in decision 5.
- **Not after `each:`.** One job per element would release the followers once per element.

Rejected:

- **`SweetTalk.after_dispatch { }`**, the in-transaction hook #248 named as the fallback: it
  gives an application a place to write its own log, but every application would write a
  different one and nothing could rebuild from it.
- **Event sourcing.** Loading an aggregate from its log changes every command's read and
  the model ADR 0030 chose; the log is kept beside the rows, not instead of them.
- **Logging only what a projection follows.** The audit needs every event, and a projection
  added later follows events nobody followed when they occurred.
- **A watermark instead of the refusal.** Jobs would carry log ids and the replay would skip
  up to one; the busy check is one query and names what to drain.
- **Resolving `after:` where the handler is written.** A projection may be declared after
  the handler that names it, and an event of a context declared later resolves only once
  every name is known, so the check runs at `macro finished`.
