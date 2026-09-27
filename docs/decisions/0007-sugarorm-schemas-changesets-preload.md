# ADR 0007: SugarORM replaces `Caramel::Model` with immutable schemas, class changesets and type-tracked preloads

Date: 2026-09-27

Status: accepted. Supersedes [decision 0002](0002-typed-persistence.md). Amends [RFC-0002](../rfc.md) §2.1–2.4 and §3.

## Context

Decision 0002 shipped `Caramel::Model` as a deliberately narrow layer: mutable classes, scalar CRUD, presence validation and hand-written SQL migrations. RFC-0002 needs more:

- pure schemas;
- compile-time association safety;
- explicit changesets;
- a fluent facade;
- typed SQL.

Several sketches in the RFC do not compile in Crystal:

- `struct Team::UpdateChangeset < SugarORM::Changeset(Team)` inherits from a generic type the RFC never defines as a struct.
- `preload(:users)` needs a return type that depends on a symbol's value.
- A `NotLoaded` error that appears "at build time" needs somewhere to live.

## Decision

1. **Schemas** are immutable structs: `struct Team < SugarORM::Schema; schema "teams" do … end; end`.
   - `field` takes `primary:`, a literal default and `renamed_from:`. The other declarations are `timestamps`, `belongs_to`, `has_many`, `has_one`, `index` and `drop_column`.
   - Instances have getters only, plus `with(**)` for a changed copy. They hold no connection and have no callbacks, and every instance is a stored row.
   - `scope name(args) { … }` defines sentence scopes (RFC-0008 §2.2).
2. **Changesets** are `abstract class SugarORM::Changeset(T)` subclasses.
   - They declare `param` fields, which are checked against the schema at compile time.
   - `validate(cs)` is written exactly as the RFC shows, and there are validators for required, presence, comparison, length, format and inclusion.
   - `unique_constraint` maps SQLSTATE 23505 to a field error.
   - `SugarORM::Repo.insert` and `SugarORM::Repo.update` return the same changeset, reporting `saved?`, `record` and `errors`.
   - A changeset accumulates errors and outcome. That is the mutable boundary, so it is a class. Schemas stay pure values.
3. **Facade.** `Team.create(**)` and `team.update(**)` build `Team::CreateChangeset`/`UpdateChangeset` when the program defines them, and otherwise a generated `Team::DefaultChangeset`. Both run through the Repo and return the changeset. The bang forms return the record or raise `SugarORM::Invalid`. Every facade method and query terminal also accepts an explicit `db` handle first (`User.create!(db, …)`, `.first!(db)`), as RFC-0006's examples use.
4. **Association safety.**
   - On a plain record, an association accessor returns a generated sentinel `Team::UsersNotLoaded(Remediation)` that has no collection methods. Any use fails to compile *at the caller's line*. The type name carries the remedy: "add `.preload(:users)` to the query that loaded this Team".
   - `preload(:users)` resolves through an overload per association whose parameter is a one-member enum. Crystal autocasts the symbol, so an unknown association is a compile error that lists the valid ones.
   - Each overload merges a loader into the query's type parameter. Preloading terminals then return `SugarORM::Loaded(Team, NamedTuple(users: Array(User)))`, where `users` is a real array.
   - Each association costs exactly one extra query.
5. **Queries are immutable.**
   - `where` keywords are generated per schema and typed: a value, `nil`, an `Array` or a `Range`. A raw `where("x > ?", v)` fragment is also available.
   - `order_by(:field, :asc)` validates the field through a generated `Field` enum.
6. **Repo.** One application pool is set at boot. `Repo.bind` binds a connection or transaction to the current fiber, which Corretto and Cold Brew use; `transaction` nests as savepoints.
7. **Typed SQL.** `SugarORM.sql(query, *args, as: {team_id: Int64, total: Int64})` returns `Array(NamedTuple)` for CTEs, window functions and `RETURNING`. It checks the result's column names and order against the declared keys and raises `SugarORM::ShapeError` on a mismatch.

## Reasons

- Macro-generated overloads, enums and type-carrying sentinels put every contract in the type system, so misuse fails at compile time and at the caller's line. Crystal's `{% raise %}` and `method_missing` report errors at the outermost top-level expression instead; this was verified during implementation.
- Changesets as classes keep the RFC's `def validate(cs)` cadence while leaving schemas purely immutable.
- Explicit handle overloads and fiber binding let tests and jobs share one transaction without global state leaking between fibers.

Principles followed:

- Manifesto 7: compile-time macros instead of runtime reflection.
- Manifesto 4: failed validation performs no write, and constraint violations stay explicit.
- Manifesto 8: `team.update(seats: 10)` reads like the intent.
- RFC-0008 §2.2: sentence scopes and preloads.
- RFC-0008 §2.6: remediation travels with the error.

## Verification

- `scripts/check orm-compilation` covers N+1 access, an unknown preload, `where`, `order_by` and changeset keyword errors, `param` type mismatches, unsupported types, non-literal defaults and a missing primary key.
- `spec/sugar_orm/*_spec.cr` covers the unit behaviour.
- `spec/integration/sugar_orm_spec.cr` (`scripts/check integration`) runs against real PostgreSQL:
  - CRUD through the facade and explicit changesets;
  - `unique_constraint`;
  - preload statement counts;
  - scopes and conditions;
  - nested savepoints and fiber binding;
  - typed SQL with a CTE, a window function and `RETURNING`.
- Generated resources use the facade end to end (`scripts/check frappe-project`).
