# ADR 0007: SugarORM maps each table to an immutable schema, writes through class changesets and keys records by a UUIDv7 the application mints

Date: 2026-09-27

Status: accepted.

## Context

An application needs pure schemas, association safety at compile time, explicit changesets and typed SQL, and Crystal cannot express a `preload` whose return type depends on a symbol's value. A record keyed by an identity column has no id until its row is written, and Crystal has no date type without a clock. PostgreSQL's conflicts surfaced as raw errors, and a report needed a total, a join or every row at once (#133).

## Decision

1. **A schema is an immutable struct that declares its table once.** An instance is a stored row: it holds no connection and has no callbacks. Each table belongs to one schema.
2. **A record is keyed by a UUIDv7, or by an Int64 the database assigns as an opt-in.** PostgreSQL 18 is the floor for UUID-keyed tables, and Caramel checks no server version. A foreign key follows its target's key type, and the framework's bookkeeping tables stay bigint.
3. **The application mints the id, in the insert changeset.** SugarORM has its own UUIDv7 generator, whose ids strictly increase within a process, and the column keeps a database default for raw SQL. A client supplies an id only through a changeset that declares it.
4. **Every type outside the built-in set is stored through a codec, as text.** A codec opts into range queries with the constant `ORDERABLE`. The decimal codec sits behind a require of its own, and refuses a value PostgreSQL would round.
5. **A calendar day is a `SugarORM::Date` in a `date` column.** It has no time of day and no zone.
6. **A text column declared as a date is retyped behind a check; every other type change halts.**
7. **Indexes and constraints are declared in the schema and named by SugarORM.** An expression check is compared by its name only.
8. **A version field refuses a stale update.**
9. **A record's JSON holds only the columns its schema lists.** A schema that lists none fails compilation where a record would be written as JSON.
10. **A changeset is a class, and the only mutable boundary.** Its params are checked against the schema at compile time, and it carries the errors and the outcome of a write. An upsert is declared on it.
11. **The facade builds a changeset and returns it.** Every facade method and query terminal also takes an explicit database handle.
12. **An association that was not preloaded has no methods.** Its accessor returns a generated sentinel type whose name carries the remedy, and a preload changes the query's return type.
13. **Queries are immutable and check names and types at compile time.** A value that may be nil does not compile in `where`; the literal `nil` is IS NULL. The top-level words `not`, `over`, `under`, `starting_with`, `ending_with` and `containing` are values keyword `where` takes; `not` keeps the rows with no value unless it says `unknown: :drop`. `where_condition` is a method of its own.
14. **The Repo holds one pool and binds connections to fibers.** A nested transaction is a savepoint.
15. **Hand-written SQL is read as named tuples of a declared shape.**
16. **PostgreSQL's conflicts raise typed errors, and retrying a transaction is opt-in and outermost.** The outermost commit's error is typed too. A retry runs with no pause. A generated Destroy answers 409 when other rows still reference its record.
17. **Aggregates return PostgreSQL's exact text.**
18. **Joins go through `belongs_to` only.** `where(<belongs_to>: parent_query)` narrows by a parent query without a join, and `not(parent_query)` leaves its rows out. Either way the parent query brings its own conditions and tenant.
19. **Batches and pages read by primary key.** The cursor is the last row's key, typed, with no encoding.

## Reasons

- Generated overloads, enums and sentinel types put every contract in the type system, so misuse fails at compile time, at the caller's line, with the remedy in the type's name. Crystal's `{% raise %}` and `method_missing` report at the outermost top-level expression instead.
- Changesets as classes keep the `def validate(cs)` cadence and leave schemas pure values.
- Explicit handles and fiber binding let tests and jobs share one transaction without global state leaking between fibers.
- An id held before the insert lets one step name a record in events, jobs, URLs and child rows without a round trip. Sequential ids also tell anyone who sees one how many records exist.
- UUIDv7 leads with time, so new keys land at the right of a B-tree index and order by creation.
- Rejected: the stdlib `UUID.v7`. It has no counter, so two ids minted in one millisecond order at random.
- Rejected: the database alone mints the id. The application would again wait for `RETURNING` to learn the key.
- Rejected: a version check for PostgreSQL 18. The first migration that creates a UUID-keyed table already fails on an older server.
- Rejected: taking an id from any changeset. A client could pick or overwrite keys; one declared param makes the choice visible.
- Text means no codec value passes through a float. GMP is a link-time dependency, so a program that stores no `BigDecimal` does not link it.
- Ranges are opt-in because a text column compares by the database's collation, not as its values do.
- A `Time` carries a zone, so a day read in one zone and written in another moves by one. Rejected: a `Time` field with a date codec, which hides the zone.
- The retype's check runs in the migration because `frappe db diff` sees a development branch, not the rows a deploy meets. Rejected: no check, which stops at the first bad value. Rejected: halting, which sends every application through add, backfill and drop.
- PostgreSQL rewrites the SQL of an expression check, so only its name can be compared.
- A `json` line makes each exposed column a decision; encoding every field leaks the ones added later.
- A lookup by a token must not match the rows whose token is NULL when the value happens to be nil.
- `where_condition` is its own method because another `where` overload turns "no parameter named" into "no overload matches".
- A conflict is a condition an application answers, with a 409 or a retry. A raw driver error makes every caller match SQLSTATE strings.
- Rejected: retrying by default, which repeats work the author never marked as safe. A retry is outermost because PostgreSQL rolled the whole transaction back.
- Rejected: sleeping between retries. A fixed pause is a guess.
- Rejected: typed sums. The type of a PostgreSQL sum depends on the column's, and only the caller knows which value to build.
- Rejected: an opaque page cursor. Encoding adds a format to version and tamper-proof.
- The words are top-level methods, as `puts` is, so a query reads the same in an action, a spec or a script; a class's own method of the same name wins inside that class.
- `not` keeps the rows with no value by default, as `IS DISTINCT FROM` does; SQL's `<>` drops them without saying so.
- Rejected: operator hashes (`{not: …}`), which accept their keys in any order, and block predicates (`where { copies > 3 }`), where Crystal cannot refuse `&&` or `||` between two conditions, so half of one is dropped silently.
- Rejected: keeping `where_null` and `where_in`; `where(field: nil)` and `where(<belongs_to>: parent)` say the same in the one `where`.
