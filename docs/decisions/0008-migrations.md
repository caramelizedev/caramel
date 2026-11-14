# ADR 0008: Migrations are derived from the declared schema on a scratch branch, proved by diffing again, and linted before they run

Date: 2026-09-27

Status: accepted.

## Context

Migrations are derived by diffing the declared schema against a catalog snapshot taken from a Latte branch, and linted for zero-lock safety. Several things need a rule:

- how the headless binary reaches the declared schema;
- how a derived migration is verified;
- how `CREATE INDEX CONCURRENTLY` and `VALIDATE CONSTRAINT` can run, since neither may run inside a migration's transaction;
- which statements count as unsafe on a brand-new table;
- how a deliberate column removal is expressed.

## Decision

The rules an application relies on are stated on the website ([site.html](../../website/source/site.html)), chiefly its SugarORM reference, in the sections cited below by anchor, and in the doc comments of [src/sugar_orm](../../src/sugar_orm) (`Differ`, `DDL`, `Linter`, `Migrator`) and [src/frappe/schema_diff.cr](../../src/frappe/schema_diff.cr). This record states what was chosen.

1. **The application binary prints its declared schema.** Every compiled application has a `schema` subcommand that prints `SugarORM::Catalog.declared` as JSON, without a database: the headless schema dump. Frappé builds the application and runs it (`site#c-commands-app`).
2. **`frappe db diff --name NAME [--dev-override]` derives migrations on a scratch branch and proves them by diffing again.** Latte clones the site's development database into a scratch branch behind the connection guard of [ADR 0012](0012-latte.md): disallow connections, terminate other backends, `CREATE DATABASE … TEMPLATE … STRATEGY FILE_COPY`, and always re-allow connections. Frappé applies any pending migrations to the branch, introspects its `pg_catalog`, diffs and lints. It writes `db/migrations/<UTC timestamp>_<name>.cr`, and online changes to a separate `…_concurrently.cr` file. It verifies the new files by rebuilding the application, migrating the branch and diffing again to empty. The branch is always dropped, and on any failure the written files are removed. What the command prints is in `site#c-sugarorm-migrations`.
3. **A new table's migration comes from the same renderer.** `frappe make resource` derives its `CREATE TABLE` migration through the same DDL renderer, offline, because the table is new (`SchemaDiff.source`).
4. **Statements that cannot run in a transaction form an online migration of their own.** A migration made only of `CREATE/DROP INDEX CONCURRENTLY`, `ALTER INDEX … RENAME TO` and `VALIDATE CONSTRAINT` statements runs outside a transaction (`Migration#transactional?`, `Linter.online?`), under the session advisory lock that covers the whole run (`Migrator#migrate`). The migrator refuses to journal an index that PostgreSQL left `INVALID`. Foreign keys and checks on existing tables are added `NOT VALID` and validated in the online migration; a validation that existing rows fail stops the migration, names the constraint and leaves it `NOT VALID` (`Migrator::ValidationFailed`, `site#c-sugarorm-migrations`).
5. **A changed index is built before the old one is dropped.** It is built under the name `<name>_swap` (`<name>_swap2` and so on when that name is taken), then the old one is dropped and the new one renamed (`Differ.swap_name`).
6. **Every other migration commits alone, and a lock timeout is retried.** A transactional migration runs in a transaction of its own, which also writes its journal row, so a failure keeps the migrations before it. A statement that hits `lock_timeout` rolls its migration back, and the migrator runs it again after 1, 2 and 4 s (`Migrator::LOCK_RETRY_DELAYS`). A fourth timeout stops `migrate` and names the migration (`Migrator::LockTimedOut`). Online migrations run with no `lock_timeout`. The wait for the advisory lock that serializes migrators keeps the connection's `lock_timeout` and is not retried: a second `migrate` that waits longer fails with PostgreSQL's lock error.
7. **The linter runs over every pending migration before any statement executes.** It refuses a migration that locks an existing table against its writes, destroys or rewrites its rows, or hides such a statement in a `DO` block, unless an annotation line above the statement names the rule and its subject. It reads dollar-quoted bodies, including a `DO` block's; a `CREATE FUNCTION` body is not read. A table the migration creates, and an index it builds, is exempt from every rule but `destructive-column` and `mixed-concurrency`. Every rule but `mixed-concurrency` accepts the annotation. The rules, each named as `frappe migrate` reports it, what each refuses and the annotation's syntax are in `site#c-sugarorm-migrations` and on `Linter`.
8. **A rename or a drop is declared in the schema, and the differ halts on anything else that loses data.** A rename comes from `field new_name : T, renamed_from: :old_name` and a drop from the schema directive `drop_column :name` (`site#c-sugarorm-schemas`). Derived SQL carries the annotations `-- caramel:allow-rename table.column`, `-- caramel:allow-drop table.column` and, for the checked text to date retype of [ADR 0007](0007-sugarorm.md), `-- caramel:allow alter-column-type table.column`, which the linter accepts (`DDL`). Hand-written SQL must state them to pass. A type change or `SET NOT NULL` that `--dev-override` derived stays plain, so the linter still warns about it. Otherwise the differ halts with a `Remediation:` line instead of emitting destructive DDL (`Differ::Halt`); the halts are listed in `site#c-sugarorm-migrations`.
9. **SugarORM owns only what it names.** It owns the CHECK constraints named `check_…`, the indexes it names `index_<table>_on_…` and the keys it names `fk_<table>_…`: an undeclared one is dropped, and any other undeclared CHECK, index or key is left in place with a note (`Differ.owned_index?`, `Differ.compare_checks`). The differ ignores `caramel_*` tables, which the framework's own migrations define ([ADR 0009](0009-cold-brew.md)).
10. **Only development may override.** `--dev-override` turns violations and overridable halts into warnings only when `CARAMEL_ENV=development`. The test and production environments, which include staging, always enforce (`Linter.enforce`).
11. **`frappe migrate` reports schema drift after migrating, read-only** (`site#c-sugarorm-migrations`).

## Reasons

- Diffing a real, disposable copy of the migrated database is the only way to see its true catalog. Diffing again after applying the output proves the derivation converges.
- Branch isolation keeps the verification away from development data.
- Separate online migrations are the only way PostgreSQL permits `CONCURRENTLY`. Refusing to journal an invalid index keeps the journal truthful, and lets an interrupted online migration be retried safely.
- Explicit rename and drop intent turns the most common source of data loss into a compile-visible, reviewable declaration.
- The lint rules cover every statement that locks an existing table against its writes for longer than a lock wait, destroys its rows, or hides such a statement in a `DO` block, because `migrate` runs while the previous binary still serves ([ADR 0032](0032-production.md)). Each is a judgment the author can overrule with an annotation that names the rule and the subject, so the review sees it; a blanket override would not.
- The linter reads dollar-quoted bodies so that a `DO` block hides nothing from it. A `CREATE FUNCTION` body is not read, because it runs only when called.
- A table the migration creates is exempt because it has no rows and no readers; so is an index the migration builds.
- Native PostgreSQL features are used directly, not abstracted.
- One transaction per migration releases each migration's locks when it commits, so an early migration's `ACCESS EXCLUSIVE` lock is not held while later ones run. Retrying a short lock wait, instead of waiting long, stalls the queries queued behind a migration's lock for seconds at a time. An online statement's `SHARE UPDATE EXCLUSIVE` lock queues no reads or writes, so a timeout would only abandon a `CONCURRENTLY` build.
- Ownership by name keeps a DBA's index or a hand-added key through the next diff, while removing a declaration still removes what it built. Building a changed index before dropping the old one keeps a unique index's guarantee through the change.
- Halts carry remediation.
