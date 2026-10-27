# ADR 0009: Cold Brew runs jobs, schedules, PubSub and cache on PostgreSQL inside the application process

Date: 2026-09-27

Status: accepted. Decisions 2, 3 and 8 are amended by ADR 0019.

## Context

Jobs, schedules, notifications and cache run on the PostgreSQL that holds domain truth: a `caramel_jobs` table written in the business transaction, `SKIP LOCKED` worker fibers, `LISTEN`/`NOTIFY` bridged to SSE, an `UNLOGGED` cache and a fiber scheduler with database leases. Several things need a rule:

- how finished jobs and partitions coexist;
- how a least-privileged runtime role can create partitions;
- how notifications reach subscribers without blocking;
- how tests drain queues;
- how the running application hosts all of this.

## Decision

1. **System tables are framework migrations** (`Caramel::ColdBrew::MIGRATIONS`, versions `20260927000001`–`…07`). Generated applications start their migration list with them. The SugarORM differ ignores `caramel_*` tables.
   - `caramel_jobs` has the columns that `Caramel::ColdBrew::MIGRATIONS` defines, including `enqueued_at` and `finished_at`. It is `PARTITION BY RANGE (enqueued_at)` with daily `caramel_jobs_pYYYY_MM_DD` partitions and a default partition. The primary key is `(id, enqueued_at)`.
   - The fetch index also excludes finished rows, because finished jobs stay in their partition until the partition is dropped. `caramel_jobs_claim` (`queue, priority DESC, id`, unclaimed rows) orders a claim without a sort, and `caramel_jobs_locked` (`locked_at`, locked rows) serves the release. A partitioned parent refuses `CREATE INDEX CONCURRENTLY`, so these builds take a `SHARE` lock per partition; a linter annotation allows them.
   - Partition DDL runs through two `SECURITY DEFINER` functions owned by the migration role. The runtime role can then maintain partitions without schema privileges, with a 2-second `lock_timeout`.
2. **Jobs** are `struct … < Caramel::ColdBrew::Job` values.
   - The job body declares `queue`, typed `param`s and `retry_on ErrorClass, attempts:, backoff: :exponential | :linear, base:`.
   - `Caramel::ColdBrew::Job.retry_on` adds global rules. The job's own rules are consulted first, then its parents', then the global rules, then the default of 3 exponential attempts from 1 second.
   - `T.enqueue(**params, run_at:, priority:)` writes through `SugarORM::Repo`'s current connection. Inside `Repo.transaction` the job therefore commits or rolls back with the business write.
   - Unknown keywords are compile errors.
   - A row stores the job's fully qualified class name, and a worker runs the compiled job of that name, or the one that declares it in `renamed_from` ([ADR 0019](0019-cold-brew-status-hooks-and-work.md)).
3. **Workers** claim with a `FOR UPDATE SKIP LOCKED` query (plus `finished_at IS NULL`) on a connection bound to the fiber, so `locked_by` is the backend that runs the job. They run `perform` and `finished_at = now()` in one transaction. A failure reschedules with backoff or sets `failed_at` and `last_error`, which is cut to 4,000 characters without NUL bytes or invalid UTF-8; when that write raises, a second one stores the class alone, and when that raises too the lock is cleared so the row returns to the queue. An idle fiber polls every second and wakes early when an enqueue's `pg_notify('caramel_jobs', queue)`, delivered on its commit, names its queue; the poll covers scheduled runs, retries and lost notifications.
4. **Maintenance** runs every 60 s, each step reported on its own so one that raises never skips the rest:
   - creates partitions for today through today + 7;
   - releases locks whose backend is gone, at any age: a backend that started after the lock was taken is a reused PID, not the locker ([ADR 0019](0019-cold-brew-status-hooks-and-work.md) fails a job on its third release);
   - vacuums expired cache rows;
   - drops partitions older than the retention window whose rows are all finished or failed.
5. **Scheduler.** `Caramel::ColdBrew.every(1.hour, "name") { … }` takes a lease per period with `pg_try_advisory_xact_lock` and a `caramel_schedules` row, so exactly one process runs each tick.
6. **PubSub.**
   - `publish` runs `pg_notify` on the current Repo connection, so the notification is delivered only on commit.
   - One broker connection per process `LISTEN`s, using Caramel's transport policy without a read timeout; TCP keepalive and a `SELECT 1` every 30 s (`Broker::PING_INTERVAL`), acknowledged within 5 s, find a connection that stopped answering. It reconnects with backoff and re-`LISTEN`s.
   - Each subscriber has an ordered mailbox drained by its own fiber, and delivery never blocks the broker.
   - A subscription also ends when its owning fiber dies, so an action that never unsubscribes does not leak. The block form of `subscribe` unsubscribes explicitly.
   - `Caramel::SSE.write(io, data, event:)` frames multi-line payloads correctly. `Caramel::SSE.relay(io, updates, event:)` writes a subscription's payloads as events with a `: ping` comment after each 15 s without one, so a dropped client ends the stream at the next heartbeat instead of at the next event.
7. **Cache.** `Caramel::Cache.write/read/fetch/delete/clear` works on the `UNLOGGED caramel_cache` table with optional TTLs.
8. **Hosting.** The generated application's `serve` calls `Caramel::ColdBrew.start(database_url)` unless `CARAMEL_ENV=test`. It uses a separate connection pool so jobs never starve requests, and it stops gracefully on SIGTERM: in-flight jobs finish, within `CARAMEL_SHUTDOWN_TIMEOUT` ([ADR 0032](0032-application-production-contract.md) decision 5).
9. **Tests.** `Caramel::ColdBrew.drain_queue!(db, queue)` runs due jobs synchronously on the test's connection until the queue is empty, including jobs enqueued by jobs, and raises on failures. A job that fails during a drain is not retried in the same drain. There is no background polling in tests.

## Reasons

- Keeping jobs, schedules, notifications and cache in the same PostgreSQL that holds domain truth removes the dual-write problem outright. It also removes Redis and other brokers.
- Security-definer maintenance preserves Latte's least-privilege runtime roles.
- A claim that sorts the due backlog and a release that scans every partition both grow with the queue until they outlast the 5 s lock timeout; an index that matches each statement's predicate and order keeps them constant. Isolated maintenance steps keep a slow release from stopping partition creation, which is what keeps the table bounded.
- Waking idle fibers with the enqueue's own notification gives a one-second poll the latency of a 50 ms one without 20 claims a second per idle fiber; the poll stays because notifications are at most once.
- Per-subscriber mailboxes keep events in order under bursts. A burst with one fiber per notification arrived out of order.
- One machine is sufficient, and state lives in the database and the hypermedia.
