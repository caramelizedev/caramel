# ADR 0019: Cold Brew reports job status, calls hooks after a failure is written, and runs without HTTP

Date: 2026-09-29

Status: accepted. Amends [ADR 0009](0009-cold-brew-queue-pubsub-cache.md) decisions 2, 3 and 8.

## Context

A signed webhook relay built on Caramel 0.4.0 ([#6](https://github.com/caramelizedev/caramel/issues/6)) used Cold Brew for delivery with retries. Three gaps made the application reach past the framework:

- **Status.** To show a delivery's attempts, next run, lock and failure, its dashboard joined its own table to `caramel_jobs`, whose partitioning and columns belong to the framework ([#4](https://github.com/caramelizedev/caramel/issues/4)).
- **Transitions.** A failure rolls back the job's transaction, and Cold Brew then writes the retry or failure with no callback, so the dashboard polled for it ([#4](https://github.com/caramelizedev/caramel/issues/4)).
- **Processes.** A second process that only worked queues needed a custom compiled entry point to start `Worker` and `Scheduler` ([#5](https://github.com/caramelizedev/caramel/issues/5)).
- **Renames.** A job renamed or moved by a deploy left its queued rows under a class name no binary compiled, and each failed on its first run ([#72](https://github.com/caramelizedev/caramel/issues/72)).

## Decision

1. **Status.** `Caramel::ColdBrew.status(id)` and `statuses(ids)` read `JobStatus` records through the current Repo connection, with `(db, …)` overloads like `enqueue`'s.
   - Each record carries id, queue, class name, attempts, `run_at`, `enqueued_at`, `locked_at`, `finished_at`, `failed_at` and a state.
   - The states are:
     - `Finished`;
     - `Failed`;
     - `Running` (locked; a dead process's lock shows until maintenance releases it);
     - `Retrying` (ran before and waits);
     - `Queued` (due);
     - `Scheduled` (not yet due).
   - `error_class` names the exception of the last failed run. The message and backtrace in `last_error` may carry secrets, so they never leave the database.
   - A job whose partition retention dropped returns nil.
2. **Hooks.** `ColdBrew.on_retry_scheduled { |event| … }` and `ColdBrew.on_failed { |event| … }` receive `RetryScheduled` and `JobFailed` events, which are serializable to JSON.
   - Each event carries the id, queue, class, attempts, the new `run_at` or `failed_at`, and the error class.
   - `Queue.run` calls hooks after it writes the transition.
   - Under a worker the transition has committed by then. Each hook runs in its own transaction, so its `publish` is delivered and its `enqueue` committed when it returns.
   - A raising hook rolls back only its own writes and is logged by class.
   - Under `drain_queue!` on a spec's connection, the transition and the hook run inside the example's transaction, as savepoints.
   - A job released by maintenance after its process died was never recorded as failed and fires no hook.
3. **Worker-only process.** The application binary's `work [--queues=NAMES] [--concurrency=N] [--no-scheduler]` runs `ColdBrew.start` without an HTTP server.
   - The flags replace `CARAMEL_WORKER_QUEUES` and `CARAMEL_WORKER_CONCURRENCY`, which `start` still validates.
   - `ColdBrew.start(url, env, scheduler: false)` leaves `every` schedules to other processes. Maintenance always runs, because it is idempotent.
   - `work` refuses pending migrations, prints a ready line once its workers are claiming jobs, and on SIGTERM or SIGINT lets in-flight jobs finish before it exits 0.
   - It refuses to run under `CARAMEL_ENV=test`, where specs drain queues.
   - `serve` starts Cold Brew inside the block that removes its socket, so invalid worker settings never leave the socket behind.
4. **Names.** `enqueue` always stores the job's current fully qualified class name, and a worker runs a row whose stored name is that name or one the job declares with `renamed_from "Old::Name", …`.
   - A declared name that is the job's own, or another job's name or alias, fails to compile; one job takes over an old name. `renamed_from` belongs to a concrete job; on an abstract parent it fails to compile.
   - A job found through an old name keeps the retry rules of the current class. A row whose name no compiled job claims still fails on its first run with `UnknownJob`, without a retry.
   - `Caramel::ColdBrew.unknown_queued_class_names(db)` returns the sorted class names of rows that are not locked, finished or failed and that no compiled job claims, empty when every queued job can run. A running job's row is not listed; a crashed worker's lock is released by maintenance, and the row is listed then. The query uses the partial index of `caramel_jobs_fetch`.
   - `work` and `migrate` log a warning naming them when they start, and stop nothing, not even when the query fails, which is logged by class: a stranded row is already recoverable by deploying the old name back or declaring it.
5. **Delivery.** Jobs run at least once: a job's own writes commit once with its completion, but a call to another service repeats when the process dies or the commit fails after the call. Receivers deduplicate on a stable identifier. PubSub notifications are at most once.

## Reasons

- Reading status through a framework API keeps `caramel_jobs` free to change behind a contract, and keeps error messages, which may hold connection URLs or form values, inside the database.
- A hook inside the failed `perform` transaction would be rolled back with it and could not describe the durable queue state. Calling hooks after the transition row is written is the first point where the state they describe is real.
- Running each hook in its own transaction makes its effects commit together and keeps a broken hook from affecting the worker or a spec's transaction.
- A row stores a name, not a reference, so the name must outlive the class that wrote it. Declaring the old name on the class that replaced it keeps the queue valid across a deploy without a data migration, and a compile error stops two jobs from silently sharing one.
- Reporting rather than refusing keeps `work` and `migrate` from blocking a deploy over rows that a rollback or a later alias fixes; the report is an API, so a deploy script can fail on it.
- The worker-only process reuses `serve`'s startup and shutdown instead of a second entry point, so a deployment runs one binary in two roles.
