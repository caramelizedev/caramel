# SugarORM schemas, changesets and request contracts

These application APIs are exported by `require "caramel"`. SugarORM is Caramel's persistence layer (RFC-0002, [ADR 0007](../decisions/0007-sugarorm-schemas-changesets-preload.md)); it runs over the application's verified `crystal-db` pool. Migrations are derived from the schemas ([ADR 0008](../decisions/0008-branch-and-diff-migrations.md)); see [the Frappé workflow](frappe-workflow.md).

## Schemas

```crystal
module App
  struct Book < SugarORM::Schema
    schema "books" do
      field id : Int64, primary: true
      field title : String
      field author : String
      field rating : Float64?
      timestamps
    end
  end
end
```

A schema is an immutable value. Every instance is a stored row with getters only; `book.with(title: "Dune")` returns a changed copy and never persists. Schemas hold no connection and have no callbacks. JSON output lists the declared columns in declaration order.

- **Fields** are `String`, `Int32`, `Int64`, `Bool`, `Float64` or `Time`, optionally nilable. A field may take a literal default (`field seats : Int32 = 5`) or `renamed_from: :old_name`.
- **Primary key.** It must be `field id : Int64, primary: true` and becomes an identity column.
- **`timestamps`** adds `created_at` and `updated_at`, which are NOT NULL and managed by SugarORM.
- **Other declarations** are `belongs_to`, `has_many`, `has_one`, `index :a, :b, unique: true` and `drop_column :legacy`.
- **Compile errors.** Unsupported types, non-literal defaults, unknown options, duplicate or reserved names and a missing primary key fail compilation at the declaration, with a remediation.

`SugarORM::Repo.database = db` binds the application pool once at boot; `Caramel.build(App, …)` does this when the application serves, and Corretto binds the verified spec database. `SugarORM::Repo.transaction { ... }` runs in a transaction and nests as savepoints. `SugarORM::Repo.bind(connection) { ... }` binds a connection or transaction to the current fiber.

## Changesets and the facade

Every write goes through a changeset. `frappe make resource` generates one changeset that serves both writes:

```crystal
module App
  class Book::Changeset < SugarORM::Changeset(App::Book)
    param title : String
    param author : String
    param rating : Float64?

    def validate(cs)
      cs.validate_presence(:title)
      cs.validate_presence(:author)
    end
  end

  alias Book::CreateChangeset = Book::Changeset
  alias Book::UpdateChangeset = Book::Changeset
end
```

`App::Book.create(**params)` builds `App::Book::CreateChangeset`, and `book.update(**params)` builds `App::Book::UpdateChangeset`; a schema without them uses a generated `DefaultChangeset` that permits every non-system field. Both run the changeset through the Repo and return it:

```crystal
changes = App::Book.create(title: contract.title, author: contract.author, rating: contract.rating)
if changes.saved?
  changes.record    # the stored App::Book
else
  changes.errors    # Hash(String, Array(String)), for example {"title" => ["can't be blank"]}
end
```

- **Params.** A `param` must name a non-system field with a compatible type. Facade and constructor keywords are the chosen changeset's params, so an unknown keyword or a mistyped value fails to compile at the caller.
- **Validity.** An invalid changeset performs no write. An insert reports every missing NOT NULL field without a default as `is required`.
- **Updates** write only the changed columns plus `updated_at`. Updating a row that no longer exists yields a `_base` error.
- **Bang forms.** `create!` and `update!` return the record or raise `SugarORM::Invalid`.
- **Delete.** `book.delete` returns whether a row was deleted.
- **Validators** are `validate_required`, `validate_presence` (non-blank text), `validate_greater_than`, `validate_less_than`, `validate_length`, `validate_format` and `validate_inclusion`. `unique_constraint(:email)` maps a unique violation on that column's index to a field error instead of raising. Caramel adds `validate_url(:field)`: a changed string must be a URL `redirect_external` accepts (`Caramel::ExternalURL`).
- **Explicit handles.** Every facade method and query terminal also accepts a `DB::Database` or `DB::Connection` first, for example `App::Book.create!(db, title: "Dune", author: "Frank Herbert")`.

A generated resource uses one class because its create and update forms submit the same fields under the same rules. When they differ, replace an alias with its own class.

## Queries

```crystal
App::Book.query.where(author: "Frank Herbert").order_by(:id, :desc).limit(20).to_a
App::Book.query.find(id)   # App::Book?
```

- **Immutability.** Queries are immutable, and every clause returns a new query.
- **`where`** keywords are checked against the fields at compile time. A value may be the field type, `nil` (`IS NULL`), an `Array` (`= ANY`) or a `Range`; `where("rating > ?", 3.0)` is a raw fragment with binds.
- **`order_by`** field names are checked at compile time.
- **Terminals** are `to_a`, `each`, `first`, `first!`, `find`, `find!` (raises `SugarORM::NotFound`), `count`, `exists?` and `delete_all`.
- **Scopes.** Named scopes (`scope active { where(archived: false) }`) chain like clauses.
- **Preloads.** `preload(:users)` loads an association with one extra query. Using an association that was not preloaded fails to compile, and the error names the `.preload(...)` remedy.
- **Typed SQL.** `SugarORM.sql(query, *args, as: {team_id: Int64, total: Int64})` returns typed rows for hand-written SQL and checks the result's column names and order.

## Request contracts and actions

```crystal
module App::Books
  struct Update < App::ApplicationAction
    contract do
      field id : Int64, min: 1
      field title : String, max: 200
      field note : String?
    end

    def handle(contract : Contract)
      # contract.id : Int64, contract.title : String, contract.note : String?
    end
  end
end
```

Fields bind by name from route parameters, then the form body, then the query; a name supplied by more than one source is a `Duplicate field` error. Body keys, and query keys on writes, that are not declared fields produce `Unknown field` errors under `_base`; unrelated GET query keys are ignored. `handle` is only called with a valid contract. Failures render 422 as the action's form (`contract_failure_page`), JSON `{"errors": ...}`, or a plain-text diagnostic depending on `Accept`. Route parameters that fail conversion or bounds answer 404 instead.

Bodies must be URL-encoded (2 MiB cap), multipart or a JSON object; multipart files are streamed to request-scoped tempfiles (64 MiB total) and bind to `Caramel::UploadedFile` fields. A JSON object's scalar members bind like form fields, but each must have its field's JSON type, `null` counts as absent, and a body that is not an object is a 422. Other media types answer 415. The application checks the signed CSRF token (`_csrf` field or `X-CSRF-Token` header) and exact origin before dispatching any POST, PUT, PATCH or DELETE. An action changes this for its route with `ingress body: :raw, limit:, csrf: false, authenticate: :method?` ([ADR 0020](../decisions/0020-action-ingress-and-json-bodies.md)).

Contracts support `String`, `Int32`, `Int64`, `Bool`, `Float64`, `Time` and `Caramel::UploadedFile`, optionally nilable, with `min:`/`max:` bounds for numbers and string lengths and `default:` values. Integers accept signed decimal text within range; floats accept finite decimal/exponent notation. Booleans accept exactly `true` or `false`. Timestamps accept RFC3339 with a timezone and become UTC. Numeric underscores, hexadecimal integers, truthy synonyms, nonfinite floats and date-only timestamps are rejected. Missing or whitespace-only fields become the default, nil when nilable, or an `is required` error. `contract.values` keeps the submitted text for redisplay.

Contracts and changesets stay separate. An action passes contract fields to the facade explicitly, as the generated `App::Book.create(title: contract.title, ...)` does. A failed changeset re-renders the form with status 422 and the changeset's errors, just as a failed contract does.

## Verification and limits

Run these with the pinned toolchain:

- `scripts/crystal spec spec/caramel spec/frappe spec/latte spec/sugar_orm`: unit behaviour of schemas, changesets, queries, the differ, DDL, linter, contracts and the generator. The generator spec checks that a generated migration equals what the differ derives for the declared catalog.
- `scripts/check integration`: SugarORM against disposable PostgreSQL through a restricted runtime role that cannot create tables. It covers facade and changeset CRUD, `unique_constraint`, preload statement counts, scopes and conditions, savepoints and fiber binding, and typed SQL.
- `scripts/check orm-compilation`: compile-time failures for N+1 access, unknown preloads, `where` and `order_by` fields, mistyped values, changeset and facade keywords, param mismatches, unsupported types, non-literal defaults and a missing primary key.
- `scripts/check contract-compilation` and `scripts/check route-compilation`: contract and route declaration errors.
- `scripts/check frappe-project`: generated SugarORM resources end to end. It migrates, checks for drift, runs `frappe db diff --name drift_probe` (which must find nothing to write), and runs the generated request specs, including blank-text refusal through the generated changeset on create and update.

Some compile errors are Crystal's own overload messages rather than custom text: unknown `where` keys, mistyped values, unknown changeset or facade keywords, and N+1 access. Each is still reported at the caller's line, and its message lists the accepted keywords or names the `.preload(...)` remedy. `order_by` directions are checked at runtime.
