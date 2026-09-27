# ADR 0008: Migrations are derived on a guarded scratch branch, verified by re-diffing, and linted before they run

Date: 2026-09-27

Status: accepted. Supersedes the hand-written SQL migration workflow of [decision 0002](0002-typed-persistence.md). Amends [RFC-0002](../rfc.md) §2.5, §2.6 and §3.

## Context

RFC-0002 §2.5 derives migrations by diffing the declared schema against a catalog snapshot taken from a Latte branch. §2.6 lints for zero-lock safety, and §3 allows a `--dev-override`. The RFC leaves several things open:

- how the "headless binary" reaches the declared schema;
- how a derived migration is verified;
- how `CREATE INDEX CONCURRENTLY` and `VALIDATE CONSTRAINT` can run, since neither may run inside the old one-transaction-per-batch migrator;
- which statements count as unsafe on a brand-new table;
- how a deliberate column removal is expressed.

## Decision

1. **Declared schema.** Every compiled application gains a `schema` subcommand that prints `SugarORM::Catalog.declared` as JSON: the headless schema dump. Frappé builds the application and runs it.
2. **`frappe db diff --name NAME [--dev-override]`**:
   1. Latte clones the site's development database into a scratch branch behind the RFC-0004 connection guard: disallow connections, terminate other backends, `CREATE DATABASE … TEMPLATE … STRATEGY FILE_COPY`, and always re-allow connections.
   2. Frappé applies any pending migrations to the branch, introspects its `pg_catalog`, diffs, and lints.
   3. It writes `db/migrations/<UTC timestamp>_<name>.cr`. Online changes go in a separate `…_concurrently.cr` file.
   4. It verifies the new files by rebuilding the application, migrating the branch and re-diffing to empty.
   5. The branch is always dropped, and on any failure the written files are removed.

   `frappe make resource` derives its `CREATE TABLE` migration through the same DDL renderer, offline, because the table is new.
3. **Online migrations.** A migration made only of `CREATE/DROP INDEX CONCURRENTLY` and `VALIDATE CONSTRAINT` statements runs outside a transaction under a session advisory lock. The migrator refuses to journal an index that PostgreSQL left `INVALID`, so an interrupted online migration can be retried safely. Foreign keys to existing tables are added `NOT VALID` and validated in the online migration.
4. **Lints.** The linter runs over every pending migration before any statement executes:
   - **Rule 1:** a blocking `CREATE INDEX` on an existing table.
   - **Rule 2:** `ADD COLUMN … NOT NULL` without `DEFAULT`.
   - **Rule 3:** a `DROP COLUMN` or `RENAME COLUMN` without an explicit origin.
   - **Mixing:** online and transactional statements in one migration.

   Tables created in the same migration are exempt from Rules 1 and 2, because they have no rows and no readers.
5. **Explicit intent.**
   - A rename comes from `field new_name : T, renamed_from: :old_name`.
   - A drop comes from the schema directive `drop_column :name`.
   - Derived SQL carries the annotations `-- caramel:allow-rename table.column` and `-- caramel:allow-drop table.column`, which the linter accepts. Hand-written SQL must state them to pass.
   - Otherwise the differ halts, with a `Remediation:` line instead of emitting destructive DDL.
6. **Environments.** `--dev-override` turns violations and overridable halts into warnings only when `CARAMEL_ENV=development`. The test and production environments, which include staging, always enforce. After migrating, `frappe migrate` reports schema drift read-only.

## Reasons

- Diffing a real, disposable copy of the migrated database is the only way to see its true catalog. Re-diffing after applying the output proves the derivation converges.
- Branch isolation keeps the verification away from development data.
- Separate online migrations are the only way PostgreSQL permits `CONCURRENTLY`. Refusing to journal an invalid index keeps the journal truthful.
- Explicit rename and drop intent turns the most common source of data loss into a compile-visible, reviewable declaration.

Principles followed:

- Manifesto 4: data integrity over everything; treat database state like Git.
- Manifesto 3: native PostgreSQL features, not abstractions.
- RFC-0008 §2.6: halts carry remediation.

## Verification

- `spec/sugar_orm/{differ,ddl,linter}_spec.cr` covers every rule, halt, rename, drop and online split.
- `spec/integration/migrations_spec.cr` (`scripts/check integration`) covers:
  - the introspection round trip;
  - transactional and online migrator paths with a real `CREATE INDEX CONCURRENTLY`;
  - lint refusal in production and override in development;
  - checksum drift.
- `scripts/check latte-postgres` covers branch creation and dropping, and shows that the source database accepts connections again afterwards.
- `scripts/check schema-diff` runs end to end in a generated project and covers:
  - `CREATE TABLE`;
  - a default-bearing addition;
  - a rename that keeps its data;
  - a separate concurrent index;
  - halts and `--dev-override`;
  - `drop_column`;
  - drift reporting;
  - dropped scratch branches.
