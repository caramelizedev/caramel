# ADR 0032: The production contract of an application binary

Date: 2026-10-10

Status: accepted.

## Context

Before this decision an application could not run on a Linux server: `serve` read `public/` from its build path, always ran Cold Brew's workers and scheduler, and dropped requests in flight on SIGTERM, and the only builds were macOS development builds. Servers, proxies and hosting providers change on their own schedule, and deploy tools sit outside the framework, so the binary states what they can rely on.

## Decision

1. **Scope.** The framework ships the release artifact and the runtime behaviour below. It ships no command that provisions servers or deploys; a deploy tool works from this contract.
2. **Release build.** `frappe build`:
   - refuses a dirty tree;
   - publishes `app/assets` into `public/` and refuses if that leaves tracked changes;
   - installs Alpine's `gmp-static`, then compiles the `shard.yml` target with `crystal build --release --static` for `linux/amd64` in `crystallang/crystal:1.22.1-alpine@sha256:9beda8a9d4a3659c29d185cc18f3fb9b382421bb6a4a59b8f266a6fb4ccc9f16`, or in the digest-pinned image `CARAMEL_BUILD_IMAGE` names; it keeps debug info and passes neither `-D caramel_development` nor `-Dpreview_mt`;
   - writes `.caramel/build/<shard>-<YYYYmmddTHHMMSSZ>-<sha7>-linux-amd64.tar.gz`, which holds `bin/<shard>` and `public/`. The time is the UTC build time; the sha is the commit's;
   - writes beside it `<artifact>.sha256`, as `sha256sum -c` reads it, and `<artifact>.sbom.json`, a CycloneDX 1.5 bill of materials: the application, Crystal, each shard at its version and commit, the musl, gc, gmp, OpenSSL, pcre2 and zlib it links at Alpine's versions, and the image digest;
   - holds nothing else: no source tree and no Node or other external runtime. A file the binary reads at run time must be embedded when it compiles (`read_file`) or be a browser-fetched asset in `public/`;
   - prints the artifact's absolute path as its only line on standard output; progress goes to standard error.

   A container engine is needed only for this build. Principle 3 governs development, not release builds.
3. **Root.** `serve` reads `public/` from `CARAMEL_ROOT` when that is set, and from the compile-time root otherwise.
4. **Process roles.**
   - `serve --no-workers` starts no Cold Brew workers and no scheduler, but keeps the PubSub broker and maintenance.
   - A production deployment runs its web processes with `serve --no-workers` and one `work` process.
   - `serve` without the flag behaves as it does today.
5. **Shutdown.** At the first SIGTERM or SIGINT, `serve` closes its listener, stops claiming jobs and starting schedule blocks, and ends every PubSub subscription, so a stream that waits on one ends. It answers requests in flight with `Connection: close`, and lets jobs and schedule blocks in flight run. It exits 0 when they finish, or when `CARAMEL_SHUTDOWN_TIMEOUT` seconds (1 to 3600, default 25) have passed, logging what was still in flight. A job cut off at that deadline rolls back, and maintenance releases it on its next pass once the backend is gone; a release is not an attempt. `work` stops the same way. A second signal exits 1 at once. A supervisor allows `CARAMEL_SHUTDOWN_TIMEOUT` plus 5 s before it kills a process. A request arriving on a kept-alive connection after the last in flight finished may go unanswered, so a deploy moves the proxy first (decision 6).
6. **Readiness.**
   - A new process is ready when its own socket answers `GET /health`, with `Host` set to the authority of `APP_ORIGIN`, with 200 and body `ok`. The generated route touches no database.
   - A deploy sends traffic to a process only after that.
   - Two processes cannot share one socket path, and `serve` refuses an occupied one. So each new process binds its own path and the proxy moves to it, as `frappe dev` does.
7. **Unknown jobs.** `APP jobs unknown` prints `unknown_queued_class_names`, one per line, and exits 1 when any exist. With no `caramel_jobs` table yet, it prints nothing and exits 0.
8. **Database.**
   - Connections use TCP with `sslmode=verify-full` (plus `sslrootcert` for a private CA), or a Unix socket in a directory owned by the application's user.
   - They are direct or session-mode, never transaction-pooled.
   - One database is owned by a migration role. A runtime role gets DML through default privileges.
   - The application needs no superuser and no extensions.
   - `APP db roles DATABASE MIGRATION_ROLE RUNTIME_ROLE` prints, without passwords, a psql script that creates those roles and that database with the grants Latte gives them, built from the same code. It grants both roles to the role that runs it, so a non-superuser can run it; that role stays a member of both until it revokes them. It refuses a name that does not match `[a-z_][a-z0-9_]*`, and before any grant it fails when an existing role has SUPERUSER, CREATEDB, CREATEROLE, BYPASSRLS or REPLICATION, so run it with `psql -v ON_ERROR_STOP=1`.
   - Each pooled connection sets `statement_timeout` and `lock_timeout` when it opens. `serve`, `work`, `seed`, `lint` and `drift` read `CARAMEL_STATEMENT_TIMEOUT` (default 30) and `CARAMEL_LOCK_TIMEOUT` (default 5); `migrate` reads `CARAMEL_MIGRATION_STATEMENT_TIMEOUT` (default 0) and `CARAMEL_MIGRATION_LOCK_TIMEOUT` (default 5). Each is whole seconds from 0 to 86400, and 0 means none. A connection's reads time out 5 s after its statement timeout, so PostgreSQL ends a slow statement and reports it before the client gives up. With no statement timeout the client waits, and TCP keepalive finds a lost server in about a minute. `migrate` retries a migration that hits its lock timeout after 1, 2 and 4 s, and runs online migrations without one ([ADR 0008](0008-branch-and-diff-migrations.md) §3).
   - A command's pool holds at most `CARAMEL_POOL_SIZE` connections (1 to 32, default 4). A checkout from it, or from Cold Brew's pool, waits `CARAMEL_POOL_TIMEOUT` seconds (1 to 300, default 5) for a free connection, then fails. A `serve` or `work` process holds at most `CARAMEL_POOL_SIZE` + queues × `CARAMEL_WORKER_CONCURRENCY` + 5 connections as the runtime role: its own pool, Cold Brew's pool with its four spares (maintenance, two schedule blocks, the recorder and console), and the LISTEN connection. `db roles` limits the runtime role to 24 connections, which must cover every process, old and new, during a deploy.
9. **Deploy rules.**
   - (a) The new binary runs `migrate` while the old one serves. The linter refuses a migration that locks an existing table against its writes, destroys or rewrites its rows, or hides such a statement in a `DO` block, unless the author annotates it ([ADR 0008](0008-branch-and-diff-migrations.md), decision 4). Compatibility with the serving binary is the author's job.
   - (b) The new binary's `jobs unknown` passes before cutover.
   - (c) The old binary's workers stop before the new binary takes traffic.
   - (d) `serve`, `work` and `seed` warn on standard error and start when the journal holds migrations the binary lacks, so an old process restarted after the new binary's `migrate` keeps serving until cutover; a migration the journal lacks still refuses (`Pending migrations`), and `migrate` and `lint` still refuse a journal ahead of them (`Drift`). Migrations never roll back: going back across one means restoring the database.
10. **Socket access.** `serve` binds `CARAMEL_SOCKET` with mode 0600 in a directory only its user can reach. With `CARAMEL_SOCKET_GROUP=GROUP` the directory may instead belong to the user and GROUP, with no group write and nothing for others. The socket then gets group GROUP and mode 0660, so a proxy running as another user in GROUP can connect. The ops socket always needs a private directory, which `CARAMEL_OPS_SOCKET` places it in.
11. **HSTS.** In production `serve` sends `Strict-Transport-Security: max-age=31536000` on every response ([ADR 0037](0037-response-security-headers.md)); a proxy need not add it.

## Reasons

- **Deployment is a separate product.** This contract is all a deploy tool needs from the binary.
- **Building off the server.** A PHP build is an install and a bundle, so a tool such as Forge runs it on the server. A Crystal release compile is too heavy for a small server, so the build runs where the developer works, as Vapor does. The pinned image keeps the build reproducible, as [ADR 0001](0001-managed-toolchain-provider.md) pins the development toolchain; overriding it, say for a patched OpenSSL, trades that for the operator's own digest, which the SBOM records.
- **A static musl binary.** One file, with no shared libraries to install on the server.
- **`gmp-static` at build time.** The image has GMP's shared library but not its archive, and a static binary that uses `BigDecimal` needs the archive. Alpine's repository for the image's release supplies it, so its revision can change between builds of one Caramel release; the SBOM records it.
- **Debug info kept.** Crema reports carry backtraces ([ADR 0027](0027-crema-tracing.md)).
- **`preview_mt` left out.** It is untested in Caramel.
- **`CARAMEL_ROOT`.** It is the smallest change that lets a binary leave its build path.
- **Separate workers.** Long jobs drain without holding the web process.
- **Workers stop before cutover.** A row whose class the running binary lacks fails without retry ([ADR 0019](0019-cold-brew-status-hooks-and-work.md) §4).
- **One shutdown deadline.** A job that never ends would hold a deploy for ever, and a supervisor needs a bound it can wait for. Ending PubSub subscriptions at the first signal stops an open SSE stream from using up the drain. A second signal is the operator's word that the wait is over.
- **Transaction-mode poolers ruled out.** LISTEN, `migrate`'s session advisory lock and `locked_by = pg_backend_pid()` need a session.
- **`CARAMEL_SOCKET_GROUP`.** A proxy that terminates TLS holds keys the application must not read, and vice versa. A group that may enter one directory and connect to one socket grants nothing else.
- **Server-side timeouts.** A client timeout that only closes its socket leaves the statement running, so an `UPDATE` can commit after the application reported a failure, and a migration queued for a lock holds every query behind it. PostgreSQL's own timeouts end the statement and roll it back. A client read timeout sends no cancel: it fires only when the server stopped answering, and crystal-pg 0.31.0 discards the backend key a cancel needs. The limits come from the environment: the client must know the statement timeout to wait past it, which rules out `ALTER ROLE … SET`, and psql refuses URL options. `migrate` has none so that `CREATE INDEX CONCURRENTLY` can finish.
- **Pool size from the environment.** How many requests a process serves at once is a deployment choice, bounded by the runtime role's connection limit and the server's `max_connections`, which only the operator knows.
- **Four spares in Cold Brew's pool.** A schedule block holds its connection until it commits with its lease, and `work` also gives the pool to Crema's recorder and console. With one spare, a long block starved maintenance and every other schedule each cycle. Maintenance, the recorder and the console each keep a connection, and two slots serve schedule blocks; a third due block waits. A fixed count keeps the budget independent of the schedule count. Rejected: a connection per schedule, whose budget grows with each `every`; releasing the lease before the block runs, which would let a failed block keep its lease.
- **Rejected:**
  - a deploy command in Frappé;
  - `SO_REUSEPORT` handover on one socket path;
  - restore points and migration rollback;
  - `--no-debug`;
  - `-Dpreview_mt`.
- **Deferred:**
  - embedded and fingerprinted assets;
  - arm64 artifacts.
- **Research:** [production hosting](https://github.com/caramelizedev/caramel-notes/blob/main/research/production-hosting.md).
