# ADR 0012: Latte supervises one PostgreSQL cluster, DNS and an HTTPS proxy per user and leaves applications to the terminal

Date: 2026-09-27

Status: accepted.

## Context

Latte has to run the shared services of local development, watch sources, give instant type feedback and clone databases. It must survive terminal sessions, several projects and daemon crashes, and it must never expose one user's database to another. Latte runs only on macOS. Caddy's undeclared default CA tries to install itself into the system trust stores ([incident note](https://github.com/caramelizedev/caramel-notes/blob/main/research/incident-2026-09-27-caddy-local-ca.md)). A developer also wants the database's view of queries, a site's HTTP traffic and one trace across several local sites, and Latte owns the cluster, the proxy and the menu bar app.

## Decision

1. **Latte is a per-user supervisor of shared services.** One daemon per user runs one PostgreSQL 18 cluster, CoreDNS and Caddy for every project. The daemon owns processes and databases and carries no agent protocol state: Frappé commands stay one-shot processes.
2. **Applications run under terminal-owned `frappe dev` sessions, not under Latte.** A session stops when its terminal does.
3. **The services outlive the daemon.** The next daemon adopts them, and adopts a process only after identifying it as its own service. It refuses when the identification is ambiguous.
4. **Latte starts on demand, and the login item is opt-in.** The login item does not ask launchd to keep Latte alive. Frappé never starts a daemon for a state root someone set explicitly: checks and fixtures run their own.
5. **Every service socket is a Unix socket only its owner can reach.** PostgreSQL listens on no TCP port, and no socket lives in a shared directory. The sockets live under the owner's home, with the home taken from the passwd database.
6. **A site takes the suffix `caramel`, `test` or `localhost`.** A `.localhost` site is reachable without administrator rights.
7. **Latte never installs trust implicitly.** Every CA Caddy can provision is declared untrusted. Trusted browser HTTPS for `.caramel` names needs the owner's one-time trust and resolver installation.
8. **`frappe dev` rebuilds on kernel events.** It does not poll the source tree. There is no `inotify` backend.
9. **The type check is reported before code generation.** One compiler run serves both the check and the native build.
10. **A database branch is an APFS clone taken behind a connection guard.** Connections are re-allowed in every outcome, and again at daemon exit and at every start, so a crash never leaves a database closed.
11. **The managed cluster collects statement statistics, in development databases only.** They live in a schema of their own, and the spec database has none. Utility statements are not tracked, and a role reads the text of its own statements only.
12. **Latte observes local sites.** The control API carries each site's errors and Latte.app raises alerts from them, each site has its own proxy access log, and the daemon collects local traces. A site's error never carries a message.
13. **The trace collector listens for OTLP/HTTP on loopback TCP.** Any local process may write. The collector serves no reads: only the owner reads, through the control socket. It holds traces in memory under a byte ceiling, and a collector that cannot bind leaves the daemon running.

## Reasons

- A shared supervisor with terminal-owned applications keeps many projects running without Docker, while each project's lifecycle stays under its developer's control.
- Starting on demand removes a manual step without adding an agent daemon. The login item is opt-in because it changes what runs at login.
- Rejected: `KeepAlive` on the login item. A daemon that exits because another one is already running would restart in a loop, and on-demand start already recovers from a crash.
- A private socket keeps "no TCP" and "no Docker" without giving other local users a path to the cluster. `/tmp` is shared by every user on the machine, and under the owner's home another user cannot create the socket directory first.
- RFC 6761 reserves `.localhost` for loopback, and browsers resolve its names without any system configuration.
- Trust stores belong to the machine owner, so Latte adds trust only when the owner asks.
- Kernel events remove the full-tree polling cost. Latte is macOS-only, so it needs no `inotify` backend.
- A type check before code generation gives the fastest feedback Crystal allows today.
- `pg_stat_statements` answers "which statement is slow" with the cost the database measured, and the statement tags Crema adds ([ADR 0027](0027-crema.md)) make the statistics attributable. Utility statements are not tracked because a password change carries a literal.
- Keeping the statistics out of `public` keeps them out of SugarORM's introspection and Corretto's catalog fingerprint.
- Local OTLP SDKs speak HTTP over TCP, so the collector is an exception to the Unix-socket rule. A browser page cannot write through DNS rebinding, and no writer can grow the daemon past its byte ceiling.
- Research: [observability](https://github.com/caramelizedev/caramel-notes/blob/main/research/observability.md).
