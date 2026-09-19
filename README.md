# Caramel

Caramel is an early Crystal framework and local development environment for complete browser applications, inspired by Laravel's integrated developer experience.

The intended workflow combines PostgreSQL, server-rendered HTML with bundled htmx 4, optional one-command authentication, and named local HTTPS projects managed by Latte. Frappé is the developer CLI.

## Current state

The toolchain feasibility milestone is complete. The first runtime slice now has reusable Crystal web primitives and a PostgreSQL-backed Bookshelf reference app with CRUD, escaped compiled views, CSRF-protected forms, and locally bundled htmx 4. Its native binary passes a named-HTTPS smoke test through Caddy over a private Unix socket.

Frappé, Latte's managed installation/service manager/menu UI, the model DSL and generators, optional authentication, and production deployment are not implemented yet. Browser-trusted local DNS/HTTPS and the complete generated-project experience remain acceptance gates. Mise is accepted for prototype tooling; consumer installation still needs clean-machine validation.

- [Developer experience design](docs/superpowers/specs/2026-09-19-caramel-developer-experience-design.md)
- [Runtime plan and remaining delivery map](docs/superpowers/plans/2026-09-19-runtime-foundation.md)
- [Bookshelf reference application](examples/bookshelf/README.md)
- [Runtime verification and limits](docs/research/runtime-verification.md)
- [Toolchain decision and remaining gates](docs/decisions/0001-managed-toolchain-provider.md)
- [Reproduce the toolchain installation](experiments/toolchain/README.md)

## Contributor checks

After installing the toolchain experiment, set `CARAMEL_TOOLCHAIN_ROOT` to its installation directory. The launchers preserve the caller's working directory and use the pinned Crystal/Shards/OpenSSL tools without shell activation.

```sh
scripts/shards install --frozen
scripts/crystal spec spec/caramel
scripts/check-views
scripts/check-compiler
scripts/integration --http-smoke
```

The integration command creates and cleans up its own database cluster and test proxy. It never uses an existing application database or changes system DNS/certificate trust. Ordinary system-installed Crystal and Shards can also be used for unit tests when `CARAMEL_TOOLCHAIN_ROOT` is absent; the integration harness requires the pinned managed tools.
