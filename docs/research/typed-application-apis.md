# Typed models and browser inputs

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

## Browser inputs

```crystal
struct BookInput
  include Caramel::FormInput
  field title : String
  field author : String
end
```

`BookInput` accepts `book[title]` and `book[author]`. The default envelope strips the `Input` suffix and uses snake case for the unqualified type name; `Admin::OrderLineInput` uses `order_line`. Override it explicitly with `form_envelope "book"`.

Controllers call `result = parse_form(BookInput)`. A successful result has a typed `result.value : BookInput?`. A failure has no value, per-field `result.errors`, and original declared text in `result.values` for a 422 form response. Branch on `if input = result.value` before constructing or updating a model. Unlike the early design excerpt, the parser does not return a typed input unconditionally; malformed input is an ordinary result rather than a runtime type exception.

The controller checks the signed token and exact origin **before returning either result**. Invalid CSRF raises `Caramel::Forbidden` and receives the application's 403 response. The existing body limit, media-type checks and malformed-encoding responses remain in force. Direct `Input.from_form(form)` is a conversion primitive and does not perform CSRF or authorization; browser controllers should use `parse_form`.

Missing required fields, duplicate keys, and unknown/envelope-mismatched keys invalidate the result. The first value of a duplicate declared field is retained for redisplay; no typed value is produced. Unknown fields are not copied into `values`. General form errors use `_base`. Views must still escape displayed values through `Caramel::View`/`Caramel::HTML`.

Inputs support the same six scalar types as models. Integers accept signed decimal text within range; floats accept finite decimal/exponent notation. Booleans accept exactly `true` or `false`. Timestamps accept RFC3339 with a timezone and become UTC. Numeric underscores, hexadecimal integers, truthy synonyms, nonfinite floats and date-only timestamps are rejected. Missing or whitespace-only nullable fields become nil; a required blank `String` remains a string for model-level presence validation. Nullable strings preserve their original whitespace when nonblank. No automatic model assignment is provided.

## Verification and remaining gates

Verified on the pinned Crystal 1.21.0 / PostgreSQL 18.6 toolchain:

- 77 runtime and Latte unit examples, including seven typed-input examples. Latte process/socket tests require normal host permissions; the initial sandbox-only run could not inspect processes or bind sockets, and the permitted rerun passed.
- 11 disposable PostgreSQL integration examples, including restricted-role model CRUD, bound SQL-looking values, every supported scalar, timestamp and no-timestamp models, primary-key declaration order, stale records and nullable queries. The runtime role cannot create tables.
- Ten model and six input compile fixtures cover valid API use and expected type/field/option failures.
- The existing native Bookshelf named-HTTPS/Unix-upstream smoke still passes with the exported APIs. That reference app is hand-authored; this is not generated-app or browser acceptance.

Run `scripts/check-model-compilation`, `scripts/check-input-compilation`, `scripts/crystal spec spec/caramel spec/latte`, and `scripts/integration --http-smoke` with the pinned toolchain. Fresh independent review remains pending: the Luna workers stopped at the account usage limit. Frappé generation, browser interaction and consumer installation remain separate acceptance gates.
