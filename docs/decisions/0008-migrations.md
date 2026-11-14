# ADR 0008: Migrations are derived from the declared schema, proved by diffing again, and linted before they run

Date: 2026-09-27

Status: accepted.

## Context

Migrations are derived by diffing the declared schema against a catalog snapshot taken from a Latte branch, and linted for zero-lock safety. The headless binary must reach the declared schema, and a derived migration must be verified. `CREATE INDEX CONCURRENTLY` and `VALIDATE CONSTRAINT` cannot run inside a migration's transaction. The reference is `site#c-sugarorm-migrations`.

## Decision

1. **The application binary prints its declared schema.** It answers from the compiled application alone, without a database. Frappé builds the application and runs it.
2. **A migration is derived by diffing the declared schema against a real catalog.** Frappé clones the development database into a scratch branch ([ADR 0012](0012-latte.md)), applies the pending migrations there, and compares the branch's catalog with the declared schema.
3. **A derived migration is proved by applying it and diffing again to empty.** A derivation that does not converge leaves no migration file. The scratch branch is always dropped.
4. **A new table's migration comes from the same renderer.** Generating a resource derives its `CREATE TABLE` without a database, because the table is new.
5. **Statements that cannot run in a transaction form an online migration of their own.** Concurrent index builds and constraint validation go in a separate migration that runs outside a transaction. A foreign key or check on an existing table is added `NOT VALID` and validated online. The migrator refuses to journal an index that PostgreSQL left invalid.
6. **A changed index is built before the old one is dropped.**
7. **Every other migration commits alone, and a lock timeout is retried.** Each transactional migration runs in a transaction of its own that also writes its journal row, so a failure keeps the migrations before it. A migration that times out waiting for a lock rolls back and runs again a few times before `migrate` stops. Online migrations run with no lock timeout.
8. **The linter runs over every pending migration before any statement executes.** It refuses a migration that locks an existing table against its writes, destroys or rewrites its rows, or hides such a statement in a `DO` block. An annotation above the statement that names the rule and its subject overrules it. A table the migration creates is exempt; a function body is not read.
9. **A rename or a drop is declared in the schema, and the differ halts on anything else that loses data.** It halts with a remedy instead of emitting destructive DDL. Derived SQL carries the annotation the linter accepts; hand-written SQL must state it.
10. **SugarORM owns only what it names.** An undeclared check, index or key that carries a SugarORM name is dropped. Any other is left in place. The framework's own tables are outside the diff.
11. **Only development may override.** There, a flag turns lint violations and overridable halts into warnings. Test and production, which includes staging, always enforce.
12. **`migrate` reports schema drift after migrating, and changes nothing.**

## Reasons

- Diffing a real, disposable copy of the migrated database is the only way to see its true catalog. Diffing again after applying the output proves the derivation converges.
- Branch isolation keeps the verification away from development data.
- A separate online migration is the only way PostgreSQL permits `CONCURRENTLY`. Refusing to journal an invalid index keeps the journal truthful and lets an interrupted online migration be retried.
- Building a changed index first keeps a unique index's guarantee through the change.
- One transaction per migration releases its locks at commit, so an early migration's exclusive lock is not held while later ones run.
- Retrying a short lock wait, instead of waiting long, stalls the queries queued behind the migration for seconds at a time. An online statement's lock queues no reads or writes, so a timeout would only abandon a build.
- The lint rules cover every statement that locks an existing table against its writes for longer than a lock wait, destroys its rows, or hides such a statement in a `DO` block, because `migrate` runs while the previous binary still serves ([ADR 0032](0032-production.md)). Each is a judgment the author can overrule with an annotation that names the rule and the subject, so the review sees it; a blanket override would not.
- The linter reads a `DO` block's body so that the block hides nothing from it. A function body is not read, because it runs only when called. A table the migration creates has no rows and no readers.
- Explicit rename and drop intent turns the most common source of data loss into a compile-visible, reviewable declaration.
- Ownership by name keeps a DBA's index or a hand-added key through the next diff, while removing a declaration still removes what it built.
- Native PostgreSQL features are used directly, not abstracted.
