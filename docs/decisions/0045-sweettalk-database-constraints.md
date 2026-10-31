# ADR 0045: SweetTalk database constraints

Date: 2026-10-28

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 4.

## Context

`has` took no options, so an aggregate could not say that a label, a code or an operation
key is unique, that a business key is looked up and so indexed, or that a shape such as "a
pending line carries no amounts" holds in the database. The only unique index SweetTalk
wrote was a projection's or a process's key. An application that needed idempotency kept a
table of claims beside its aggregates, checked uniqueness with a read under a row lock,
which a caller could skip, and wrote a hand migration for an index, whose violation then
surfaced as a raw `SugarORM::UniqueViolation` rather than a refusal (#166).

## Decision

1. **`has` takes `unique:`, `index:` and `check:`.** `has label : String, unique: true`
   is a unique index over the attribute's columns, refused with `Crate label must be
   unique`; `unique: "A crate with this code already exists."` gives the sentence.
   `index: true` is a plain index. `check: {"quantity >= 0", "A crate cannot hold less
   than nothing."}` is a CHECK written against the stored columns, with the sentence it is
   refused with. An attribute's columns are what `key` would store: a reference's
   `<name>_id`, a composite value's part columns.
2. **An aggregate or an entity declares `unique`, `index` and `check` over several
   attributes.** `unique :source_key, :bundle, otherwise: "…"` and `index :owner, :state`
   name attributes declared above them, or `state` once `moves` is; `check
   :pending_is_zero, "state <> 'pending' OR (debit = 0 AND credit = 0)", otherwise: "…"`
   names its SQL. `otherwise:` is required on `check` and optional on `unique`, whose
   default sentence is `<Aggregate> <a> and <b> must be unique`. A name that is not an
   attribute, a list of entities, a `check` without a sentence, a `unique:` that is not
   `true` or a sentence, and a constraint declared twice do not compile, naming the fix.
3. **The DDL is SugarORM's.** A unique or plain index is the schema's `index …, unique:
   true` line, named `index_<table>_on_<columns>` and shortened past 63 bytes by SugarORM;
   in a tenanted context SugarORM appends the tenant column to a unique index, so the value
   is unique within each tenant and two tenants may share it. A check is the schema's
   `check :name, "sql"` line, named `check_<table>_<name>_<hash>`, the FNV-1a hash of the
   SQL as eight hex digits, so a changed SQL is a new constraint, as a lifecycle's or a
   list's check is; a name over 63 bytes does not compile. On an existing table `frappe db
   diff` builds the index `CONCURRENTLY` and adds the check `NOT VALID`, then validates it
   in a migration of its own, which the zero-lock linter accepts.
4. **A violation is a refusal.** Each aggregate and entity records `SWEETTALK_REFUSALS`,
   its constraint names to their sentences. Its save rescues `SugarORM::UniqueViolation`
   and `CheckViolation` and raises `SweetTalk::Refusal` with the sentence the constraint
   maps to; a constraint SweetTalk did not declare stays the error it is. A command's
   refusal rolls the transaction back, clears the events and reloads the aggregate; an
   action answers 422; a `create` or a factory raises and leaves no row.
5. **An entity's `unique` is unique within its parent, the aggregate or entity that holds
   it** ([ADR 0050](0050-sweettalk-nested-entities.md)). Its index leads with the
   parent's column, `(<parent>_id, columns)`. A save now deletes the entity rows it loaded
   and dropped before it writes, so an entity replaced by one with the same value saves.
   Two entities that swap their values still violate: the index is not deferrable.
6. **A projection and a process take none of these.** Their `key` is their identity and
   its unique index is theirs; `unique`, `index`, `check` and the `has` options there do
   not compile.
7. **Limits.** A soft-removed aggregate keeps its row, so a unique value stays reserved
   until a partial index can exclude it (#133). A new unique index over rows that already
   hold duplicates fails `CREATE INDEX CONCURRENTLY`, leaving an INVALID index that halts
   the next `frappe db diff` until it is dropped, and a new check stops `frappe migrate` on
   the rows that break it (ADR 0039 decision 8); find duplicates first with `SELECT
   <columns>, count(*) FROM <table> GROUP BY <columns> HAVING count(*) > 1`. A partial
   index (`where:`) and a custom sentence for a value's own bound are not declared here.

## Reasons

- **The database is the only place a race cannot pass.** A read under a lock is only as
  safe as the next caller who forgets the lock; a unique index refuses the second writer
  whatever path it took.
- **Options on `has`, words for the rest.** One attribute's uniqueness, index or check
  reads best on its line; what spans attributes or the lifecycle's state needs a line of
  its own, and `check` always needs SQL.
- **By name, not by column.** `Changeset#unique_constraint` maps by the leading column and
  prefixes the error with it, which is not a sentence; SweetTalk maps the constraint's own
  name, which SugarORM derives the same way at compile time and at run time, so a composite
  index and a check map alike.
- **A sentence is required on `check`.** SQL says nothing a reader can show; `unique`
  can name its attributes, so it may default.
- **Hash the SQL.** PostgreSQL rewrites a check's text, so SugarORM compares expression
  checks by name only; a name that carries the SQL's hash makes an edit a replacement.
- **Deletes first.** Writing the new entity before deleting the old one makes a replaced
  value a duplicate for one statement; deferrable constraints would hide this and every
  other violation until commit, past the refusal that reloads the aggregate.

Rejected:

- **A claims table written in the same transaction.** It is the workaround this replaces:
  nothing in the schema says which aggregate it guards.
- **Deferrable unique indexes.** A violation at commit would surface after the command's
  rescue, as a raw error, and an upsert cannot target a deferrable index.
- **A partial unique index for soft-removed rows.** It needs `where:` on an index, which
  SugarORM does not declare yet (#133); the limit is named instead of worked around.
- **A custom sentence for a value's bound.** A value's refusal is the value's, shared by
  every attribute of that type; a per-attribute sentence is a change of its own.
