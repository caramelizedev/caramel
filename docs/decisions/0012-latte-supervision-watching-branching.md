# ADR 0012: Latte supervises shared services, watches with kqueue, type-checks first, and branches with guarded APFS clones

Date: 2026-09-27

Status: accepted. Amends [RFC-0004](../rfc.md) §2.1, §2.2 and §3.

## Context

RFC-0004 sketches four things:

- Latte supervising the application over POSIX signals;
- PostgreSQL on the shared socket `/tmp/.s.PGSQL.5432`;
- `kqueue`/`inotify` watching followed by an instant `--no-codegen` check;
- a connection-guarded template clone behind `caramel latte branch create`.

The implementation has to survive terminal sessions, several projects and daemon crashes, and it must never expose one user's database to another. Latte runs only on macOS: its menu app, port relay, installers and toolchain are all macOS-specific.

## Decision

1. **Supervision.**
   - The `latte daemon` is a per-user service supervisor. It starts, adopts after restart and recovers the shared PostgreSQL 18 cluster, CoreDNS and Caddy.
   - Applications run under terminal-owned `frappe dev` sessions. These register a development gateway socket with Latte and stop when the terminal does.
   - The daemon owns processes and databases. It carries no agent protocol state: Frappé commands stay one-shot processes (RFC-0005).
2. **Unix sockets.**
   - PostgreSQL listens only on a private, owner-only socket directory inside Latte's state (`listen_addresses = ''`) with SCRAM authentication. It does not use the shared `/tmp/.s.PGSQL.5432`, because `/tmp` is shared by every user on the machine.
   - Application sockets live in the site's owner-only run directory under the same runtime root, not at the charter's `/tmp/caramel_app.sock`, for the same reason.
3. **Kernel watching.**
   - `Caramel::Latte::Watcher` registers `EVFILT_VNODE` kqueue filters on every watched directory and file (opened `O_EVTONLY`) and rescans a directory when it changes.
   - `frappe dev` hashes the tree only after a kernel event, then waits out a 50 ms debounce before the type check. It was 200 ms until 2026-09-29; a multi-file save that outlasts the shorter window only cancels a check and costs CPU, since a newer change stops an obsolete check or build.
   - Crystal 1.21's event loop cannot wait on a kqueue descriptor, so the watcher drains with a zero-timeout `kevent` every 25 ms and never blocks the scheduler.
   - There is no `inotify` backend, because Latte is macOS-only.
4. **Tier-1 feedback first.** Every uncached source change first runs `crystal build --no-codegen` with the development flags.
   - On failure, `frappe dev` shows the diagnostics immediately on the site's error page and in the terminal (`Type check failed in N ms`) and skips code generation.
   - On success, it continues to the native build.
5. **Branching.**
   - `frappe db branch create NAME | list | delete NAME` replaces `caramel latte branch create`. It asks the daemon, which applies the RFC's guard: `ALLOW_CONNECTIONS false`, terminate other backends, `CREATE DATABASE … TEMPLATE … STRATEGY FILE_COPY`, and always re-allow.
   - Latte's `postgresql.conf` sets `file_copy_method = clone`, so the file copy is an APFS copy-on-write clone.
   - `create` prints the branch URL. `frappe dev --branch NAME` runs the app against it.
6. **Crash safety.** The daemon restores `ALLOW_CONNECTIONS` on every Caramel database, both in its SIGINT/SIGTERM exit path and at every start. Starting after a SIGKILL therefore repairs a guard that a crash left in place.

## Reasons

- A shared supervisor with terminal-owned apps keeps many projects running without Docker, while each project's lifecycle stays under its developer's control.
- A private socket keeps "no TCP" and "no Docker" without giving other local users a path to the cluster.
- Kernel events remove the full-tree polling cost. A type check before code generation gives the fastest feedback Crystal allows today. The timing targets are deferred.
- One CLI (`frappe`) for every developer command avoids a second binary vocabulary.

Principles followed:

- Manifesto 3: no Docker; native processes, Unix sockets and kernel events.
- Manifesto 4: branch and verify database state like Git, and never lock developers out.

## Verification

- `spec/latte/watcher_spec.cr` covers create, modify, delete and rename events and a new file in a new directory. It fails if the rescan or the inode check is removed.
- `scripts/check frappe-project --dev` covers:
  - watched rebuilds, and Tier-1 type-error feedback with no code generation followed by recovery;
  - `--branch`-style runtime override against a real Latte branch.
- `scripts/check latte-postgres` covers `file_copy_method = clone` and branch creation, listing and dropping, with the source database accepting connections again.
- `scripts/check latte-daemon` covers guard release on SIGTERM and after SIGKILL plus restart. It fails if the SIGTERM release is removed.
- The 200 ms feedback and 50–100 ms clone targets are performance claims and are deferred.
