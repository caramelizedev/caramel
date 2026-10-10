# ADR 0007: SugarORM replaces `Caramel::Model` with immutable schemas, class changesets and type-tracked preloads

Date: 2026-09-27

Status: accepted.

## Context

An application needs pure schemas, compile-time association safety, explicit changesets, a fluent facade and typed SQL. Crystal cannot express some natural shapes directly:

- a changeset struct inheriting from a generic type;
- `preload(:users)` with a return type that depends on a symbol's value;
- a `NotLoaded` error that appears at build time and needs somewhere to live.

## Decision

1. **Schemas** are immutable structs: `struct Team < SugarORM::Schema; schema "teams" do … end; end`.
   - `field` takes `primary:`, a literal default, `renamed_from:`, `codec:` and `version:`. The other declarations are `timestamps`, `belongs_to`, `has_many`, `has_one`, `index`, `drop_column` and `check`.
   - Each table belongs to one schema: a second concrete schema that names the same table fails to compile, naming both.
   - A field's type is `String`, `Int32`, `Int64`, `Bool`, `Float64` or `Time`, optionally nilable, or any type with `codec: C`, where `C.sql_type` (`numeric`, `numeric(P,S)`, `jsonb` or `text`), `C.encode(value) : String` and `C.decode(text)` map it to text. Rows read codec columns as text and writes bind the encoded text, so no value passes through a float. A codec field takes no default and matches only a value or nil in `where` and in `validate_inclusion`. Adding a required codec field to an existing table halts, as it has no default. `SugarORM::JSONB(T)` stores a JSON-serializable type.
   - `check stock: 0.., quantity: 1..10` bounds `Int32` or `Int64` fields with inclusive integer ranges, and `check :dates, "starts_at < ends_at"` adds a named SQL expression. Each becomes the CHECK constraint `check_<table>_<name>`, where a range check's name is its column. Range checks are compared by their bounds; expression checks by name only, because PostgreSQL rewrites their SQL, so changing one needs a new name.
   - `field lock_version : Int32, version: true` (Int32 or Int64, no default; the column defaults to 0) versions the record. Every changeset update adds `AND "lock_version" = $n` and increments it. A changeset given `lock_version:` checks that version instead of the loaded one, so a form carries the version it was rendered from. A mismatch writes nothing, adds `_base` "Record changed since you loaded it" and sets `stale?`. Deletes do not check it.
   - Instances have getters only, plus `with(**)` for a changed copy. They hold no connection and have no callbacks, and every instance is a stored row.
   - `scope name(args) { … }` defines sentence scopes.
2. **Changesets** are `abstract class SugarORM::Changeset(T)` subclasses.
   - They declare `param` fields, which are checked against the schema at compile time.
   - `validate(cs)` is written as a method taking the changeset, and there are validators for required, presence, comparison, length, format and inclusion.
   - `unique_constraint` maps SQLSTATE 23505 to a field error.
   - `check_constraint(:name)` maps SQLSTATE 23514 of a declared range check to `must be at least N` or `must be at most N` on its field; an expression check needs `on: :field`. The default changeset maps every unique index and range check.
   - `SugarORM::Repo.insert` and `SugarORM::Repo.update` return the same changeset, reporting `saved?`, `record` and `errors`.
   - `upsert on: :tea_id, update: [:sold]` in a changeset class makes its insert `INSERT … ON CONFLICT` on that declared unique index, whose tenant column a tenanted schema adds. The `update:` fields the changeset writes are set from the new row, along with `updated_at` and the version. With none, `DO NOTHING` and a second read return the existing row. Either way `record` is the stored row. The target must be a declared unique index, and the key and update fields must be params of that changeset, checked at compile time.
   - A changeset accumulates errors and outcome. That is the mutable boundary, so it is a class. Schemas stay pure values.
3. **Facade.** `Team.create(**)` and `team.update(**)` build `Team::CreateChangeset`/`UpdateChangeset` when the program defines them, and otherwise a generated `Team::DefaultChangeset`. Both run through the Repo and return the changeset. The bang forms return the record or raise `SugarORM::Invalid`. Every facade method and query terminal also accepts an explicit `db` handle first (`User.create!(db, …)`, `.first!(db)`).
4. **Association safety.**
   - On a plain record, an association accessor returns a generated sentinel `Team::UsersNotLoaded(Remediation)` that has no collection methods. Any use fails to compile *at the caller's line*. The type name carries the remedy: "add `.preload(:users)` to the query that loaded this Team".
   - `preload(:users)` resolves through an overload per association whose parameter is a one-member enum. Crystal autocasts the symbol, so an unknown association is a compile error that lists the valid ones.
   - Each overload merges a loader into the query's type parameter. Preloading terminals then return `SugarORM::Loaded(Team, NamedTuple(users: Array(User)))`, where `users` is a real array.
   - Each association costs exactly one extra query.
5. **Queries are immutable.**
   - `where` keywords are generated per schema and typed: a value, `nil`, an `Array` or a `Range`. A raw `where("x > ?", v)` fragment is also available.
   - `order_by(:field, :asc)` validates the field through a generated `Field` enum.
   - `lock` adds `FOR UPDATE` to the rows a query returns and keeps its tenant scope. It runs only inside a transaction, and `count`, `exists?` and `delete_all` refuse it. Applications lock several rows in one order (`order_by(:id).lock`) and still check permissions.
6. **Repo.** One application pool is set at boot. `Repo.bind` binds a connection or transaction to the current fiber, which Corretto and Cold Brew use; `transaction` nests as savepoints.
7. **Typed SQL.** `SugarORM.sql(query, *args, as: {team_id: Int64, total: Int64})` returns `Array(NamedTuple)` for CTEs, window functions and `RETURNING`. It checks the result's column names and order against the declared keys and raises `SugarORM::ShapeError` on a mismatch.

## Reasons

- Macro-generated overloads, enums and type-carrying sentinels put every contract in the type system, so misuse fails at compile time and at the caller's line. Crystal's `{% raise %}` and `method_missing` report errors at the outermost top-level expression instead.
- Changesets as classes keep the `def validate(cs)` cadence while leaving schemas purely immutable.
- Explicit handle overloads and fiber binding let tests and jobs share one transaction without global state leaking between fibers.
- Failed validation performs no write, and constraint violations stay explicit.
- Codecs keep exact decimals and structured values out of the type map, so an application that never uses BigDecimal never links GMP, and each application picks its own decimal type.
- Remediation travels with the error, in the sentinel's type name.
