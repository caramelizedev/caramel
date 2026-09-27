# Caramel

Caramel is an early Crystal framework and local development environment for complete browser applications, inspired by Laravel's integrated developer experience.

The intended workflow combines PostgreSQL, server-rendered HTML with bundled htmx 4, optional one-command authentication, and named local HTTPS projects managed by Latte. Frappé is the developer CLI.

## Current state

The toolchain feasibility milestone is complete. The runtime has reusable Crystal web primitives: PostgreSQL persistence, escaped compiled views, CSRF-protected forms and locally bundled htmx 4. The reference application is the project Frappé generates; `scripts/check frappe-project` builds one with resources, runs its request specs and serves its native binary through Caddy over named HTTPS and a private Unix socket.

Latte now has a private project registry, managed PostgreSQL, DNS/HTTPS configuration, a shared service daemon and a native macOS menu client. Disposable integration checks cover service startup, crash recovery, two-site HTTPS and database retention. Its fixed macOS resolver/port installer passed review; applying that system installation awaits explicit authorization. System-resolved, browser-trusted HTTPS remains an acceptance gate.

The application workflow branch adds a narrow typed model API, Caramel Core (compile-time checked routes, typed request contracts, actions with HTML or JSON egress, multi-target htmx partials and client islands), and the native Frappé CLI. It creates and restores projects, generates typed resources, applies explicit migrations, and runs specs against separately provisioned PostgreSQL databases. Resource generation produces editable models, actions with request contracts, views, route helpers, migrations and request specs. The watched development loop now rebuilds safely, serves same-origin build diagnostics, refreshes assets and cleans up terminal-owned app processes. Smaller individual generators, custom commands, dependency editing, optional authentication, and production deployment remain unfinished. Consumer installation and the complete browser experience still need acceptance testing. Mise provides the pinned private toolchain.

- [Caramel RFCs](docs/rfc.md)
- [Typed model and request contract APIs, verification and limits](docs/research/typed-application-apis.md)
- [Frappé generated-project workflow and current limits](docs/research/frappe-workflow.md)
- [Development watcher, process ownership and acceptance limits](docs/research/frappe-development.md)
- [Development performance measurements and limits](docs/research/development-performance.md)
- [Latte supervisor verification and limits](docs/research/latte-supervisor.md)
- [Toolchain decision and remaining gates](docs/decisions/0001-managed-toolchain-provider.md)
- [Resumable toolchain installer component](docs/research/toolchain-installer.md)
- [Optional Crystal editor tools (Zed)](docs/editor-tools.md)

## Contributor checks

Install the pinned toolchain (Apple Silicon, Apple Command Line Tools required) with `scripts/install-toolchain --root <dir>`, then set `CARAMEL_TOOLCHAIN_ROOT` to that directory. The selection and lockfile live in `tools/toolchain/`. The launchers preserve the caller's working directory and use the pinned Crystal/Shards/OpenSSL tools without shell activation.

```sh
scripts/shards install --frozen
scripts/crystal spec spec/caramel
scripts/check views
scripts/check compiler
scripts/check model-compilation
scripts/check route-compilation
scripts/check contract-compilation
scripts/check toolchain-paths
scripts/check integration
```

The integration command creates and cleans up its own database cluster. It never uses an existing application database or changes system DNS/certificate trust. Ordinary system-installed Crystal and Shards can also be used for unit tests when `CARAMEL_TOOLCHAIN_ROOT` is absent; the integration harness requires the pinned managed tools.

Latte contributor checks additionally require the pinned CoreDNS artifact and the macOS Swift compiler:

```sh
scripts/install-latte-tools --help
scripts/build-latte
scripts/check latte-postgres
scripts/check latte-network
scripts/check latte-daemon
scripts/check native
scripts/build-frappe
scripts/check frappe-project
scripts/check frappe-project --dev
scripts/check dev-child
scripts/check dev-retirement
scripts/check runtime-diagnostics
```

These checks use isolated temporary state and local listeners. Running the system integration installer or `latte trust install` is a separate, explicit operation; neither is part of the test commands.

Optional language servers for Zed and other editors: `scripts/build-frappe`, `bin/frappe lsp install`, then `scripts/check editor-tools`; see [docs/editor-tools.md](docs/editor-tools.md).
