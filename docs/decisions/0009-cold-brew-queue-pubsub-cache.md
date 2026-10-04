# ADR 0009: Cold Brew runs jobs, schedules, PubSub and cache on PostgreSQL inside the application process

Date: 2026-09-27

Status: accepted. Decisions 3 and 8 are amended by ADR 0019.

## Context

Jobs, schedules, notifications and cache run on the PostgreSQL that holds domain truth: a `caramel_jobs` table written in the business transaction, `SKIP LOCKED` worker fibers, `LISTEN`/`NOTIFY` bridged to SSE, an `UNLOGGED` cache and a fiber scheduler with database leases. Several things need a rule:

- how finished jobs and partitions coexist;
- how a least-privileged runtime role can create partitions;
- how notifications reach subscribers without blocking;
- how tests drain queues;
- how the running application hosts all of this.

## Decision

1. **System tables are framework migrations** (`Caramel::ColdBrew::MIGRATIONS`, versions `20260927000001`–`…03`). Generated applications start their migration list with them. The SugarORM differ ignores `caramel_*` tables.
   - `caramel_jobs` has the columns that `Caramel::ColdBrew::MIGRATIONS` defines, including `enqueued_at` and `finished_at`. It is `PARTITION BY RANGE (enqueued_at)` with daily `caramel_jobs_pYYYY_MM_DD` partitions and a default partition. The primary key is `(id, enqueued_at)`.
   - The fetch index also excludes finished rows, because finished jobs stay in their partition until the partition is dropped.
   - Partition DDL runs through two `SECURITY DEFINER` functions owned by the migration role. The runtime role can then maintain partitions without schema privileges, with a 2-second `lock_timeout`.
2. **Jobs** are `struct … < Caramel::ColdBrew::Job` values.
   - The job body declares `queue`, typed `param`s and `retry_on ErrorClass, attempts:, backoff: :exponential | :linear, base:`.
   - `Caramel::ColdBrew::Job.retry_on` adds global rules. The job's own rules are consulted first, then its parents', then the global rules, then the default of 3 exponential attempts from 1 second.
   - `T.enqueue(**params, run_at:, priority:)` writes through `SugarORM::Repo`'s current connection. Inside `Repo.transaction` the job therefore commits or rolls back with the business write.
   - Unknown keywords are compile errors.
3. **Workers** claim with a `FOR UPDATE SKIP LOCKED` query (plus `finished_at IS NULL`) on a connection bound to the fiber, so `locked_by` is the backend that runs the job. They run `perform` and `finished_at = now()` in one transaction. A failure reschedules with backoff or sets `failed_at` and `last_error`.
4. **Maintenance** runs every 60 s:
   - creates partitions for today through today + 7;
   - drops partitions older than the retention window whose rows are all finished or failed;
   - releases stale locks whose backend is gone;
   - vacuums expired cache rows.
5. **Scheduler.** `Caramel::ColdBrew.every(1.hour, "name") { … }` takes a lease per period with `pg_try_advisory_xact_lock` and a `caramel_schedules` row, so exactly one process runs each tick.
6. **PubSub.**
   - `publish` runs `pg_notify` on the current Repo connection, so the notification is delivered only on commit.
   - One broker connection per process `LISTEN`s, using Caramel's transport policy without a read timeout. It reconnects with backoff and re-`LISTEN`s.
   - Each subscriber has an ordered mailbox drained by its own fiber, and delivery never blocks the broker.
   - A subscription also ends when its owning fiber dies, so an action that never unsubscribes does not leak. The block form of `subscribe` unsubscribes explicitly.
   - `Caramel::SSE.write(io, data, event:)` frames multi-line payloads correctly.
7. **Cache.** `Caramel::Cache.write/read/fetch/delete/clear` works on the `UNLOGGED caramel_cache` table with optional TTLs.
8. **Hosting.** The generated application's `serve` calls `Caramel::ColdBrew.start(database_url)` unless `CARAMEL_ENV=test`. It uses a separate connection pool so jobs never starve requests, and it stops gracefully on SIGTERM: in-flight jobs finish.
9. **Tests.** `Caramel::ColdBrew.drain_queue!(db, queue)` runs due jobs synchronously on the test's connection until the queue is empty, including jobs enqueued by jobs, and raises on failures. A job that fails during a drain is not retried in the same drain. There is no background polling in tests.

## Reasons

- Keeping jobs, schedules, notifications and cache in the same PostgreSQL that holds domain truth removes the dual-write problem outright. It also removes Redis and other brokers.
- Security-definer maintenance preserves Latte's least-privilege runtime roles.
- Per-subscriber mailboxes keep events in order under bursts. A burst with one fiber per notification arrived out of order.
- One machine is sufficient, and state lives in the database and the hypermedia.
