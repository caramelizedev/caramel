# Typed models and request contracts

The Frappé workflow branch implements these application APIs over the existing database pool and bounded form parser. They are exported by `require "caramel"`. The CLI and generated-project workflow are still in progress.

## Models

```crystal
abstract class ApplicationRecord < Caramel::Model
end

class Book < ApplicationRecord
  table :books
  field id : Int64?, primary: true
  field title : String
  field author : String
  timestamps
  validates :title, presence: true
end
```

Configure `Caramel::Model.database = db` once during application boot, using the already verified `Caramel::Database.open` connection. All models share that application-owned pool. Model methods neither open another URL nor change schema. The application closes the pool on shutdown.

Construct with declared writable fields: `Book.new(title: "Dune", author: "Frank Herbert")`. Required fields must be supplied with the declared type; nullable fields default to nil. Primary keys must be `Int64?`, are nil before insertion, and have no setter. Timestamp getters are `Time?`; matching migrations must provide PostgreSQL timestamp defaults. Ordinary application instance variables are not persisted.

`save` validates and then inserts or updates, returning a Boolean. Presence validation rejects nil and blank strings; false and zero are present. Invalid records expose `errors : Hash(String, Array(String))` and perform no write. Saving a deleted or externally removed record returns false with an `_base` error; it does not insert a replacement. Database constraint and transport exceptions propagate to the application's exception boundary. There are no callbacks, implicit transactions across several saves, or association loading.

`Book.find(id)` returns `Book?`. `delete` (also `destroy`) returns whether a row was deleted; repeated deletion returns false. Saving an existing identity-only record checks existence without issuing an empty update or firing update triggers.

```crystal
Book.where(author: "Frank Herbert").order(created_at: :desc).limit(20).to_a
```

Conditions accept declared scalar field types or nil; nil produces `IS NULL`. Values use PostgreSQL bind parameters. Unknown source-level fields fail compilation. Ordering permits only `:asc` and `:desc`; limits must be positive. Queries are lazy until `to_a` and **mutate when chained**. Create separate query objects for independently varying searches. This API does not validate runtime database schema: apply the matching migrations explicitly.

Supported fields are `String`, `Int32`, `Int64`, `Bool`, `Float64`, `Time`, and their nullable equivalents. Unsupported field types and field/validation options fail compilation. This intentionally small surface is documented in the [persistence decision](../decisions/0002-typed-persistence.md).

## Request contracts and actions

```crystal
module App::Books
  class Update < App::ApplicationAction
    contract do
      field id : Int64, min: 1
      field title : String, max: 200
      field note : String?
    end

    def handle(contract : Contract) : Result | Caramel::Response
      # contract.id : Int64, contract.title : String, contract.note : String?
    end
  end
end
```

Fields bind by name from route parameters, then the form body, then the query; a name supplied by more than one source is a `Duplicate field` error. Body keys, and query keys on writes, that are not declared fields produce `Unknown field` errors under `_base`; unrelated GET query keys are ignored. `handle` is only called with a valid contract. Failures render 422 as the action's form (`contract_failure_page`), JSON `{"errors": ...}`, or a plain-text diagnostic depending on `Accept`. Route parameters that fail conversion or bounds answer 404 instead.

Bodies must be URL-encoded (2 MiB cap) or multipart; multipart files are streamed to request-scoped tempfiles (64 MiB total) and bind to `Caramel::UploadedFile` fields. Other media types answer 415. The application checks the signed CSRF token (`_csrf` field or `X-CSRF-Token` header) and exact origin before dispatching any POST, PUT, PATCH or DELETE.

Contracts support `String`, `Int32`, `Int64`, `Bool`, `Float64`, `Time` and `Caramel::UploadedFile`, optionally nilable, with `min:`/`max:` bounds for numbers and string lengths and `default:` values. Integers accept signed decimal text within range; floats accept finite decimal/exponent notation. Booleans accept exactly `true` or `false`. Timestamps accept RFC3339 with a timezone and become UTC. Numeric underscores, hexadecimal integers, truthy synonyms, nonfinite floats and date-only timestamps are rejected. Missing or whitespace-only fields become the default, nil when nilable, or an `is required` error. `contract.values` keeps the submitted text for redisplay. No automatic model assignment is provided.

## Verification and remaining gates

Verified on the pinned Crystal 1.21.0 / PostgreSQL 18.6 toolchain:

- 77 runtime and Latte unit examples, including seven typed-input examples. Latte process/socket tests require normal host permissions; the initial sandbox-only run could not inspect processes or bind sockets, and the permitted rerun passed.
- 11 disposable PostgreSQL integration examples, including restricted-role model CRUD, bound SQL-looking values, every supported scalar, timestamp and no-timestamp models, primary-key declaration order, stale records and nullable queries. The runtime role cannot create tables.
- Ten model and six input compile fixtures cover valid API use and expected type/field/option failures.
- The existing native Bookshelf named-HTTPS/Unix-upstream smoke still passes with the exported APIs. That reference app is hand-authored; this is not generated-app or browser acceptance.

Run `scripts/check model-compilation`, `scripts/check contract-compilation`, `scripts/check route-compilation`, `scripts/crystal spec spec/caramel spec/latte`, `scripts/check integration` and `scripts/check frappe-project` with the pinned toolchain. Fresh independent review remains pending: the Luna workers stopped at the account usage limit. Frappé generation, browser interaction and consumer installation remain separate acceptance gates.
