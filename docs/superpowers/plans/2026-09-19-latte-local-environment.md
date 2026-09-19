# Latte Local Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the reference application at an actual system-resolved, browser-trusted `https://bookshelf.caramel`, with managed PostgreSQL and a compact native macOS menu-bar manager.

**Architecture:** A Crystal service manager owns a private per-user registry, PostgreSQL cluster, DNS process, and Caddy instance. Frappé and a native Swift menu-bar application use its owner-restricted Unix control socket. System resolver, standard-port listeners and certificate-trust setup use a narrowly scoped installer action; application and service-manager processes remain unprivileged. A loopback bind probe on this host rejects unprivileged ports 80/443. Use a fixed launchd socket-activation relay for these two ports to Caddy’s high loopback ports, with the relay running as the installing user. Do not alter PF/firewall rules or displace existing listeners.

**Tech Stack:** Existing pinned Crystal/PostgreSQL/Caddy toolchain; CoreDNS 1.14.7 official native binary, verified by the artifact/configuration probe; Swift/AppKit for the initial macOS menu-bar UI.

---

This is the next subsystem plan. The runtime plan still tracks browser acceptance; the complete product also requires Frappé generation/watch workflows, model/typed-input APIs, optional authentication, and production artifacts. None of those are replaced by this subsystem.

## Shared contracts

Default state root: `~/Library/Application Support/Caramel`. Tests and contributor development set `CARAMEL_HOME` to a newly owned private temporary directory. Never inspect, stop, reconfigure, or claim an existing Herd/Homebrew PostgreSQL or proxy process.

State files and directories:

```text
registry.json                  versioned site metadata, no passwords
services/postgres/18/           managed cluster, retained on project removal
services/caddy/                 instance-specific data/config/CA
services/dns/                   exact registered-hosts file and Corefile
logs/                          bounded service logs
secrets/                       mode-0600 administrative credentials
install-receipt.json            owned system changes and CA fingerprint
```

Socket state lives in `/private/tmp/caramel-<uid>-<first12-sha256-of-canonical-root>/` (0700), with `latte.sock`, `sites/<site-id>/` and `postgres/` below it. Keeping runtime paths short avoids macOS’s Unix-socket pathname limit even for long usernames or state paths. Durable data stays under the state root. Both native UI and daemon derive this path identically.

Site names must be ASCII lowercase letters/digits/hyphens, start with a letter, and not end in a hyphen. Canonical project directories identify sites; re-registering the same name/directory is idempotent, while conflicting names/directories fail without mutation. Domains use `.caramel` by default; `.test` requires an explicit project choice. Upstreams must be sockets in that site's owned runtime directory, never arbitrary TCP addresses supplied by a client.

IPC protocol v1:

```text
GET    /v1/status               service state, health, version; no secrets
GET    /v1/sites                registered site summaries
POST   /v1/sites                {name, directory, suffix}; register/provision
DELETE /v1/sites/:id            unregister routes only; preserve database data
POST   /v1/services/start       reconcile/start owned services
POST   /v1/services/stop        stop owned services without deleting data
POST   /v1/sites/:id/upstream   {socket}; validate and atomically route
```

Bind IPC in an owned 0700 directory with a 0600 socket and verify the peer UID where the platform supports it. Registry writes must use atomic replacement under a process lock. This is a boundary between users, not a sandbox against arbitrary code running under the same user account.

## Task 1: Provider and state boundary

Files: `src/latte/paths.cr`, `src/latte/registry.cr`, `src/latte/site.cr`, `spec/latte/registry_spec.cr`, managed tool manifest/lock, `docs/research/latte-dns.md`.

- [x] Verify a pinned official Darwin-arm64 CoreDNS artifact and checksum, exact-host configuration, localhost-only binding, UDP/TCP answers, unknown-name behavior, and live hosts-file reload. Stop all probe-owned processes.
- [x] Add registry specs for idempotency, naming/path collisions, malformed hostnames, unsupported versions, atomic updates, private modes, and socket-path escape rejection.
- [x] Implement versioned registry/path primitives and run their focused specs. Secrets must never enter registry JSON or normal status output.

## Task 2: Managed PostgreSQL

Files: `src/latte/postgres.cr`, `src/latte/process.cr`, `spec/latte/postgres_spec.cr`, `scripts/check-latte-postgres`.

- [x] Add real owned-cluster checks for start/restart durability, existing-data preservation, wrong-major refusal, no TCP listener, separate development/spec databases and roles, and a fixed total connection budget.
- [x] Initialize only a new owned cluster with UTF8/UTC, private socket directory, SCRAM credentials, and an administrative secret outside repositories. Provision separate migration-owner and restricted runtime roles; runtime credentials cannot create/alter/drop schema or administer roles. Test credentials cannot connect to the development database.
- [x] Use explicit process identity/ownership records and readiness checks; never stop by a stale unverified PID. A failed start must close owned resources, preserve data, redact secrets, and report a concrete diagnostic.
- [x] Verify backup/restore on a disposable cluster. Reject implicit major upgrades. Project unregister never deletes a cluster or database.
- [ ] Record the PostgreSQL major in generated project configuration with Frappé.

## Task 3: DNS, HTTPS and trust installation

Files: `src/latte/dns.cr`, `src/latte/proxy.cr`, `src/latte/trust.cr`, `scripts/install-local-integration`, `spec/latte/proxy_spec.cr`.

- [x] Exercise exact `.caramel` DNS answers on a loopback-only high port and build a scoped `/etc/resolver/caramel` configuration using the supported macOS resolver port directive. Preserve unrelated resolver files and network settings.
- [x] Configure the owned Caddy instance with owner-only Unix administration, an instance-specific internal CA, and exact registered-host routes to validated private sockets. Reconcile complete owned configuration idempotently instead of appending duplicate routes.
- [x] Test an actual certificate-verified request through Caddy for two different named sites; reject unknown hosts and invalid upstreams. Diagnose occupied 80/443 listeners without displacing them.
- [x] Prepare a concrete installer transaction for the fixed resolver file and per-user CA trust, recording prior state and the owned fingerprint. Include a reviewed fixed launchd listener-helper installation for loopback ports 80/443, forwarding only to the owned Caddy high ports. Limit privileged code to these fixed operations; no arbitrary project shell commands run elevated. Complete build/preflight checks before invoking OS authorization when required.
- [ ] Apply the system integration after the pending explicit approval; automatic approval review rejected execution before any system changes.
- [ ] Verify system lookup and unmodified browser/curl trust without `--resolve`, explicit test CA flags, or certificate bypass. Test renewal/restart and owned-only uninstall/rotation cleanup.

## Task 4: Service manager and menu-bar application

Files: `src/latte.cr`, `src/latte/server.cr`, `src/latte/supervisor.cr`, `latte/macos/Latte.swift`, `latte/macos/Info.plist`, `scripts/build-latte`.

- [x] Implement the IPC contract with owner checks, bounded request sizes, consistent JSON errors, redacted status, and meaningful service readiness. Add an overall process-start deadline; the runtime database driver's per-address/inactivity timeouts do not supply a global DNS/TLS/startup deadline.
- [x] Build a small native Swift/AppKit menu application showing sites and service states, with open-site/open-folder/open-log actions and explicit start/stop controls. The UI uses the same service-manager contract as Frappé and does not independently spawn or own database/proxy processes.
- [ ] Verify launch, quit, restart and stale-state recovery. Closing the menu UI must not delete data or silently terminate shared services; background behavior must be explicit.

## Task 5: Complete the browser gate

Files: Bookshelf runtime entry point/configuration, `scripts/check-latte`, runtime verification record.

- [ ] Register Bookshelf and a second reference site; provision managed DBs, apply explicit migrations, start the native application behind its named HTTPS origin, and verify two sites coexist.
- [ ] In a real browser, create/edit/delete books, test invalid submissions and stored HTML escaping, navigate history, disable JavaScript for the same forms, check mobile layout and focus behavior, and inspect console/network failures.
- [ ] Verify OS/browser-trusted HTTPS, host-only cookies, same-origin CSRF, source/static isolation, daemon restart, PostgreSQL restart durability, and project unregister without data loss.
- [ ] Independently review specification compliance and code quality, resolve findings, rerun affected checks, and commit the verified subsystem. Keep unfinished Frappé/model/auth/deployment work in the full delivery map.
