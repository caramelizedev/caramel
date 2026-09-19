# Runtime milestone verification

Date: 2026-09-19

## Implemented scope

The reusable runtime now includes HTTP routing and response helpers, bounded allowlisted URL forms, CSRF verification, a public-directory-only asset handler, per-request controllers, escaped compiled ECR, a bounded PostgreSQL pool with verified TCP TLS, and explicit transactional migrations with a checksum journal.

The Bookshelf reference app exercises CRUD and accessible ordinary forms, escaped stored content, validation retention, and full/partial HTML with bundled htmx 4.0.0. Its persistence is explicit parameterized SQL; the model/typed-input/route macro DSL and generated-project contracts are not yet implemented.

## Repeatable checks

Set `CARAMEL_TOOLCHAIN_ROOT` to an installation produced by the toolchain experiment. Run commands from the repository root:

```sh
scripts/shards install --frozen
scripts/crystal spec spec/caramel
scripts/check-views
scripts/check-compiler
python3 -m unittest discover -s experiments/toolchain/tests -v
scripts/integration --http-smoke
```

`spec/fixtures/views/unknown_local_compile.cr` is intentionally invalid. Compiling it must fail at `unknown_local.html.ecr` with `missing_local` unresolved. The fixture proves template-local type checking; it is not part of the passing spec directory.

The integration harness never reads `DATABASE_URL`. It creates fresh private temporary state, supplies `CARAMEL_OWNED_*` URLs itself, and runs PostgreSQL 18.6. Application/spec roles have no superuser/role-creation/database-creation privileges; each role owns only its database. Runtime-versus-migration credential separation belongs to the managed Latte provisioning milestone and is not claimed by this harness.

## Observed results

- Unit suite: 34 examples, no failures or compiler warnings at the reviewed runtime checkpoint.
- Existing toolchain harness: five Python tests pass.
- Real PostgreSQL integration: eight examples pass, covering parameterized input, separate databases/non-superuser roles/UTC, explicit migration idempotency and rollback, checksum drift, cleanup after failed lazy-connection setup, real trusted TLS, wrong-host rejection, untrusted-CA rejection, plaintext-downgrade/malformed/EOF negotiation rejection before startup, and Bookshelf request CRUD/validation/escaping/CSRF/htmx, including escaped title updates.
- Actual native binary behind Caddy: named TLS server `bookshelf.caramel` verified with the harness CA and curl `--resolve`, reverse-proxied over a private Unix socket. Homepage and exact bundled htmx bytes returned successfully.
- Observed warm native Bookshelf compilations ranged from 1.876 to 2.553 seconds on this host. These are small-application measurements, not a general performance guarantee.

## Remaining acceptance work

Real browser interaction, history/focus/mobile visual checks, system-resolved `.caramel` names and OS/browser-trusted certificates remain unverified here. The harness deliberately does not install DNS or CA trust. These tests move to the managed Latte workflow, where they can exercise the actual default browser experience.

Database timeouts are per-address connect and per-operation inactivity limits; macOS DNS resolution, Unix connect, and a peer that keeps sending data are not covered by a hard overall deadline. The Latte/production gates must add a startup deadline and address blocking DNS.

This milestone does not implement Frappé, Latte's service lifecycle/menu UI, the model DSL/generators, authentication/mailbox, source-rebuild supervision, or production Linux/static deployment. The full experience specification remains the delivery target.
