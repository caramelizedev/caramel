# ADR 0032: An application ships as one static Linux binary with a stated runtime contract

Date: 2026-10-10

Status: accepted.

## Context

An application has to run on a Linux server it was not built on, run its workers apart from its web process, and finish what is in flight when it is told to stop. Deploy tools sit outside the framework, so the binary states what they can rely on. The same binary is the last thing between the proxy and the browser, so it sets the security headers and serves static files itself.

## Decision

1. **The framework ships an artifact and a runtime contract, not a deploy tool.**
2. **The release build compiles a static `linux/amd64` binary in a digest-pinned container, off the server.** The rule against containers governs development, not release builds. The build keeps debug info and leaves multithreading off.
3. **The artifact is one tarball of the binary and `public/`, with a checksum and a bill of materials beside it.** It holds no source tree and no external runtime. A file the binary reads at run time is embedded at compile time or is an asset in `public/`.
4. **Web and workers are two roles of one binary, run as separate processes ([ADR 0009](0009-cold-brew.md)).**
5. **Shutdown drains what is in flight under one deadline.** The first signal stops new work and ends every PubSub subscription. A second signal exits at once.
6. **A process is ready when its own socket answers the health route.** Each new process binds a socket path of its own.
7. **The database is reached over a verified session by two least-privileged roles.** A migration role owns the database and a runtime role gets DML only; the application needs no superuser and no extensions. Connections are never transaction-pooled.
8. **PostgreSQL enforces the statement and lock timeouts, and the environment sets them.** The client waits longer than the statement timeout.
9. **The new binary migrates while the old one serves, and migrations never roll back.** Compatibility with the serving binary is the migration author's job ([ADR 0008](0008-migrations.md)). The old workers stop before the new binary takes traffic.
10. **`serve` listens on a Unix socket that its user alone, or one named group, can reach.** The socket sits in a directory closed to everyone else. Naming a group lets a proxy that runs as another user connect.
11. **Every response carries the security headers, and `serve`, not the proxy, adds HSTS in production.** HSTS has no `includeSubDomains`, no `preload`, and no setting for either.
12. **The content security policy is strict by default; the application changes it once, and an action changes it for one response.** A directive that is added starts from the sources of `default-src`, and every name and source is validated. A nonce belongs to one response and exists only when an action asks.
13. **No path leaves `public/`, and a hidden path is served only under `.well-known`.** Whatever no file answers goes to the router.
14. **A file is streamed and cached by its name.** Only a name that carries a version is cached as immutable. Range requests are not supported.

## Reasons

- Deployment is a separate product; the contract is all a deploy tool needs from the binary. Rejected: a deploy command in Frappé.
- A Crystal release compile is too heavy for a small server, so the build runs where the developer works. The pinned image keeps it reproducible.
- A static binary is one file, with no shared libraries to install on the server. Deferred: arm64 artifacts.
- Crema's error reports carry backtraces. Rejected: `--no-debug`. Rejected: `-Dpreview_mt`, untested in Caramel.
- Separate workers let long jobs drain without holding the web process.
- A job that never ends would hold a deploy for ever, and a supervisor needs a bound it can wait for. Ending subscriptions at the first signal stops an open stream from using up the drain; a second signal is the operator's word that the wait is over.
- Rejected: `SO_REUSEPORT` handover on one socket path.
- Rejected: transaction-mode poolers. LISTEN, the migration advisory lock and job claims need a session.
- A client timeout that only closes its socket leaves the statement running, so a write can commit after the application reported a failure. PostgreSQL's own timeout ends the statement and rolls it back, and the longer client wait lets PostgreSQL report it first.
- The client must know the statement timeout to wait past it. Rejected: `ALTER ROLE … SET`.
- Workers stop before cutover because a queued job whose class the running binary lacks fails without retry.
- Rejected: restore points and migration rollback.
- A proxy that terminates TLS holds keys the application must not read, and the reverse. A group that may enter one directory and connect to one socket grants nothing else.
- A policy the application can change keeps the default strict and writes the exception where the need is.
- An absent directive falls back to `default-src`, so writing only the new source would block the origin's own requests.
- A header built from strings is an injection point; validation keeps a value inside its directive.
- A nonce that repeats can be replayed; one taken only when an action asks leaves other responses with the strict default.
- The binary knows its environment, and a proxy that forgets HSTS leaves the site downgradable.
- A parent domain may serve sites that are not HTTPS-only, and a preload entry is hard to take back.
- Allowing exactly `.well-known` serves ACME and app-link files while `.env` and `.git/` stay unservable. Rejected: a hard 404 for hidden paths, which would block an application's own route.
- Streaming keeps a large file out of memory.
- Assets are not fingerprinted, so an unversioned name keeps its name while its content changes. Rejected: `immutable` for every file. Deferred: embedded and fingerprinted assets.
- Assets are small, and the proxy in front of `serve` is the place for ranges.
