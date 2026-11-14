# ADR 0009: Cold Brew runs jobs, schedules, PubSub and cache on PostgreSQL inside the application process

Date: 2026-09-27

Status: accepted.

## Context

An application needs background jobs, recurring tasks, notifications to open pages and a cache. Each is usually a second system beside the database, and a write that must reach both can reach only one. A signed webhook relay built on Caramel ([#6](https://github.com/caramelizedev/caramel/issues/6)) then reached past the framework: it joined its own table to the jobs table to show status, polled for retries and failures ([#4](https://github.com/caramelizedev/caramel/issues/4)), needed a custom entry point for a process that only worked queues ([#5](https://github.com/caramelizedev/caramel/issues/5)), and lost queued jobs when a deploy renamed their class ([#72](https://github.com/caramelizedev/caramel/issues/72)).

## Decision

1. **Jobs, schedules, notifications and the cache live in the PostgreSQL that holds the application's data.** Their tables are framework migrations.
2. **A job is written in the business transaction.** It commits or rolls back with the business write.
3. **Finished jobs leave by partition, not by row.** The runtime role maintains partitions through security-definer functions, without schema privileges.
4. **A worker claims a job with `SKIP LOCKED` on the connection that runs it.** The lock therefore names the database backend that does the work.
5. **Jobs run at least once.** A job's own writes commit once, with its completion. A call to another service can repeat, and receivers deduplicate.
6. **A dead backend's lock is released from `pg_stat_activity`, and released runs are counted apart from attempts.** A release spends no retry attempt, and a job released too often fails.
7. **Idle workers poll and are woken by the enqueue's notification.**
8. **Maintenance is one idempotent pass that runs in every process.** Its steps are isolated, so one that raises never skips the rest.
9. **A job row stores a class name, and the class declares its old names.** Two jobs that claim one name fail compilation. Queued rows whose name no compiled job claims are reported through an API and a warning; they stop neither a worker nor a migration.
10. **Job status is read through a framework API that keeps error text in the database.** A caller sees a state and the error's class, never its message or backtrace.
11. **Retry and failure hooks run after the transition is written, each in its own transaction.** A raising hook rolls back only its own writes.
12. **PubSub is `LISTEN`/`NOTIFY`: at most once, delivered on commit.** Each subscriber has an ordered mailbox drained by its own fiber, and a subscription ends with the fiber that owns it.
13. **The cache is an unlogged table.**
14. **A schedule takes a database lease per period, so exactly one process runs it.**
15. **The application process hosts Cold Brew on a connection pool separate from the requests', and one binary has two roles.** A worker-only command runs the server's startup and shutdown without an HTTP server ([ADR 0032](0032-production.md)).
16. **Specs drain queues synchronously; no worker runs in the test environment.**

## Reasons

- Keeping jobs, schedules, notifications and cache in the PostgreSQL that holds domain truth removes the dual-write problem outright, and one machine is sufficient.
- Security-definer maintenance preserves least-privilege runtime roles.
- Waking idle fibers with the enqueue's own notification gives a slow poll the latency of a fast one. The poll stays because notifications are at most once.
- Maintenance runs in every process because it is idempotent. Isolated steps keep a slow lock release from stopping partition creation, which is what keeps the table bounded.
- A process can die for reasons outside the job, so a released run spends no attempt. A job that ends its process on every run must still stop, so releases are bounded.
- Rejected: a minimum age before a lock is released. `pg_stat_activity` is the ground truth that a waiting period only approximated.
- A row stores a name, not a reference, so the name must outlive the class that wrote it. Declaring the old name on the class that replaced it keeps the queue valid across a deploy without a data migration, and a compile error stops two jobs from silently sharing one.
- Rejected: refusing to start over unknown queued names. A stranded row is recoverable by deploying the old name back or declaring it, and the report is an API, so a deploy script can fail on it.
- Reading status through a framework API keeps the jobs table free to change behind a contract, and keeps error messages, which may hold connection URLs or form values, inside the database.
- Rejected: a hook inside the failed job's transaction. It would be rolled back with the job and could not describe the durable queue state.
- A hook in its own transaction commits its effects together and keeps a broken hook from affecting the worker or a spec's transaction.
- Rejected: one fiber per notification, under which a burst arrived out of order. Per-subscriber mailboxes keep events in order.
- A subscription that ends with its fiber means an action that never unsubscribes does not leak.
- A separate pool keeps jobs from starving requests.
- Rejected: a second entry point for the worker-only process. Reusing the server's startup and shutdown lets a deployment run one binary in two roles.
