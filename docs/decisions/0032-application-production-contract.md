# ADR 0032: The production contract of an application binary

Date: 2026-10-10

Status: proposed.

## Context

An application must run on a Linux server. Today it cannot:

- `serve` reads `public/` from the path the binary was built in, so a binary moved to a server fails to start.
- `serve` always runs Cold Brew's workers and scheduler, so a web process cannot be replaced without also replacing its workers.
- `serve` stops its listener on SIGTERM and closes without answering the requests in flight.
- The only builds are macOS development builds.

Servers, proxies and hosting providers change on their own schedule, and deploy tools sit outside the framework. So the binary states what any deploy tool can rely on.

## Decision

1. **Scope.** The framework ships the release artifact and the runtime behaviour below. It ships no command that provisions servers or deploys. Any deploy tool works from this contract.
2. **Release build.** `frappe build`:
   - refuses a dirty tree;
   - publishes `app/assets` into `public/` and refuses if that leaves tracked changes;
   - compiles the `shard.yml` target with `crystal build --release --static` in `crystallang/crystal:1.21.1-alpine@sha256:bf35489a8273a606368bd6a7ab2e24d01f950ca919c85ba4fe4c5bf10cd7a67e` for `linux/amd64`, keeping debug info and passing neither `-D caramel_development` nor `-Dpreview_mt`;
   - writes `.caramel/build/<shard>-<YYYYmmddTHHMMSSZ>-<sha7>-linux-amd64.tar.gz`, which holds `bin/<shard>` and `public/`. The time is the UTC build time; the sha is the commit's.

   A container engine is needed only for this build. Principle 3 governs development, not release builds.
3. **Root.** `serve` reads `public/` from `CARAMEL_ROOT` when that is set, and from the compile-time root otherwise.
4. **Process roles.**
   - `serve --no-workers` starts no Cold Brew workers and no scheduler, but keeps the PubSub broker and maintenance.
   - A production deployment runs its web processes with `serve --no-workers` and one `work` process.
   - `serve` without the flag behaves as it does today.
5. **Shutdown.** On SIGTERM or SIGINT, `serve` closes its listener, answers the requests in flight with `Connection: close`, and exits when they finish or after 25 s.
6. **Readiness.**
   - A new process is ready when its own socket answers `GET /health`, with `Host` set to the authority of `APP_ORIGIN`, with 200 and body `ok`. This is the generated route; it touches no database.
   - A deploy sends traffic to a process only after that.
   - Two processes cannot share one socket path, and `serve` refuses an occupied one. So each new process binds its own path and the proxy moves to it, as `frappe dev` does.
7. **Unknown jobs.** `APP jobs unknown` prints `unknown_queued_class_names`, one per line, and exits 1 when any exist.
8. **Database.**
   - Connections use TCP with `sslmode=verify-full` (plus `sslrootcert` for a private CA), or a Unix socket in a directory owned by the application's user.
   - They are direct or session-mode, never transaction-pooled.
   - One database is owned by a migration role. A runtime role gets DML through default privileges.
   - The application needs no superuser and no extensions.
   - `APP db roles DATABASE MIGRATION_ROLE RUNTIME_ROLE` prints, without passwords, the statements Latte runs for those names. The SQL moves out of `src/latte/postgres.cr` so both share it.
9. **Deploy rules.**
   - (a) The new binary runs `migrate` while the old one serves. The zero-lock linter keeps migrations from blocking writes ([ADR 0008](0008-branch-and-diff-migrations.md)); keeping them compatible with the binary still serving is the migration author's job.
   - (b) The new binary's `jobs unknown` passes before cutover.
   - (c) The old binary's workers stop before the new binary takes traffic.
   - (d) A binary that lacks an applied migration refuses to start (`Drift`). Migrations never roll back, so going back across a migration means restoring the database, and a cutover that fails after `migrate` means rolling forward or restoring.

## Reasons

- **Deployment is a separate product.** This contract is all a deploy tool needs from the binary, and any tool can be written against it.
- **Building off the server.** A PHP build is a dependency install and a bundle, so a deploy tool such as Forge can run it on the server. A Crystal release compile is too heavy for a small server, so the build runs where the developer works, as Vapor does. The pinned image keeps the build reproducible, as [ADR 0001](0001-managed-toolchain-provider.md) pins the development toolchain.
- **A static musl binary.** One file, with no shared libraries to install on the server.
- **Debug info kept.** Crema reports carry backtraces ([ADR 0027](0027-crema-tracing.md)).
- **`preview_mt` left out.** It is untested in Caramel.
- **`CARAMEL_ROOT`.** It is the smallest change that lets a binary leave its build path.
- **Separate workers.** Long jobs drain without holding the web process.
- **Workers stop before cutover.** A row whose class the running binary lacks fails without retry ([ADR 0019](0019-cold-brew-status-hooks-and-work.md) §4).
- **Transaction-mode poolers ruled out.** LISTEN, `migrate`'s session advisory lock and `locked_by = pg_backend_pid()` need a session.
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
