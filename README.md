# Caramel

Caramel is an early Crystal framework and local development environment for complete browser applications, inspired by Laravel's integrated developer experience.

The intended workflow combines PostgreSQL, server-rendered HTML with bundled htmx 4, optional one-command authentication, and named local HTTPS projects managed by Latte. Frappé is the developer CLI.

## Current state

The toolchain feasibility milestone is complete. The first runtime slice now has reusable Crystal web primitives and a PostgreSQL-backed Bookshelf reference app with CRUD, escaped compiled views, CSRF-protected forms, and locally bundled htmx 4. Its native binary passes a named-HTTPS smoke test through Caddy over a private Unix socket.

Latte now has a private project registry, managed PostgreSQL, DNS/HTTPS configuration, a shared service daemon and a native macOS menu client. Disposable integration checks cover service startup, crash recovery, two-site HTTPS and database retention. Its fixed macOS resolver/port installer passed review; applying that system installation awaits explicit authorization. System-resolved, browser-trusted HTTPS remains an acceptance gate.

The application workflow branch adds a narrow typed model API and typed browser inputs with PostgreSQL and compiler checks. Frappé, generators, optional authentication, and production deployment are not implemented yet. The complete generated-project experience and consumer installation still need validation on a clean supported machine. Mise is accepted for prototype tooling.

- [Developer experience design](docs/superpowers/specs/2026-09-19-caramel-developer-experience-design.md)
- [Runtime plan and remaining delivery map](docs/superpowers/plans/2026-09-19-runtime-foundation.md)
- [Bookshelf reference application](examples/bookshelf/README.md)
- [Runtime verification and limits](docs/research/runtime-verification.md)
- [Typed model and input APIs, verification and limits](docs/research/typed-application-apis.md)
- [Latte plan](docs/superpowers/plans/2026-09-19-latte-local-environment.md)
- [Latte supervisor verification and limits](docs/research/latte-supervisor.md)
- [Toolchain decision and remaining gates](docs/decisions/0001-managed-toolchain-provider.md)
- [Reproduce the toolchain installation](experiments/toolchain/README.md)
- [Resumable toolchain installer component](docs/research/toolchain-installer.md)

## Contributor checks

After installing the toolchain experiment, set `CARAMEL_TOOLCHAIN_ROOT` to its installation directory. The launchers preserve the caller's working directory and use the pinned Crystal/Shards/OpenSSL tools without shell activation.

```sh
scripts/shards install --frozen
scripts/crystal spec spec/caramel
scripts/check-views
scripts/check-compiler
scripts/check-model-compilation
scripts/check-input-compilation
scripts/check-toolchain-paths
scripts/integration --http-smoke
```

The integration command creates and cleans up its own database cluster and test proxy. It never uses an existing application database or changes system DNS/certificate trust. Ordinary system-installed Crystal and Shards can also be used for unit tests when `CARAMEL_TOOLCHAIN_ROOT` is absent; the integration harness requires the pinned managed tools.

Latte contributor checks additionally require the pinned CoreDNS artifact and the macOS Swift compiler:

```sh
scripts/install-latte-tools --help
scripts/build-latte
scripts/check-latte-postgres
scripts/check-latte-network
scripts/check-latte-daemon
```

These checks use isolated temporary state and local listeners. Running the system integration installer or `latte trust install` is a separate, explicit operation; neither is part of the test commands.
