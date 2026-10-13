Reference / Routes and contracts

# Every input, declared.

Map each method and path to one action, and declare the typed fields that action accepts.

## Declare the routes {#c-routing-draw}

All routes live in one `Caramel::Router.draw` block in `config/routes.cr`. Each line names a verb, a path and an action. The verbs are `get`, `post`, `put`, `patch` and `delete`.

**config/routes.cr · after frappe make resource Book**

```crystal
module App
  Caramel::Router.draw do
    get "/", App::Home::Show
    get "/books", App::Books::Index
    get "/books/new", App::Books::New
    post "/books", App::Books::Create
    get "/books/:id", App::Books::Show
    patch "/books/:id", App::Books::Update
    delete "/books/:id", App::Books::Destroy
    # Frappé resource routes
  end
end
```

A path starts with `/`. Static segments use letters, digits and `._~-`. A parameter is `:snake_case`, such as `:id`, and appears once per path. A path has at most 32 segments.

## Let the compiler check the table {#c-routing-checks}

The route table is checked when the application compiles. Each of these stops the build:

- a line that is not one of the five verbs with a string path and an action constant, such as `resources :books`;
- a malformed path, a repeated parameter or more than 32 segments;
- an action that is undefined, does not inherit from `Caramel::Action`, or has no `contract do … end` block (an empty one is fine);
- a parameter without a contract field of the same name;
- a parameter field that is not a non-nilable `String`, `Int32` or `Int64`, or a field value bound from one, without `default:`;
- two routes that match the same requests (`DUPLICATE ROUTE`);
- a static route declared after a parameter route that would catch it (`AMBIGUOUS ROUTE ORDER`). Declare `/books/new` before `/books/:id`.

A missing field names the route, the contract block and the fix:

**Compiler output · excerpt, paths shortened**

```bash
❌ ROUTE CONTRACT MISMATCH
Route: '/books/:book_id' defines parameter ':book_id'
Action: 'App::Books::Show::Contract' is missing 'field book_id : Type'
  --> config/routes.cr:9:5
Contract: app/actions/books/show.cr:3:5
Remediation: add `field book_id : Int64` to the contract block of App::Books::Show.
```

## Know what a request matches {#c-routing-matching}

Static segments win over parameters, and matching backtracks. `GET /books/new` reaches `New`, and `GET /teams/new/members` can still reach `/teams/:team_id/members`. Empty segments never match a parameter, so `/books/` is not `/books`.

- No route at the path answers 404 with `Not found`.
- A route at the path with another method answers 405 with `Method not allowed` and an `Allow` header, such as `GET, HEAD, PATCH`.
- HEAD runs the GET route and drops the body. It keeps the headers and sets `Content-Length`, except on streamed responses.
- A route parameter that fails its field answers 404. With `field id : Int64, min: 1`, both `/books/abc` and `/books/0` are not found.
- A path over 32 segments answers 404. A malformed path escape answers 400.

HTML forms can only send GET and POST. A POST form with a `_method` field of `PATCH`, `PUT` or `DELETE`, in any case, is routed as that method. Any other value answers 400. The override is refused with 405 when the target route reads its body differently, for example through its own `ingress`. JSON bodies do not override; send the real method.

## Declare the contract {#c-routing-contract}

Every action declares the fields it accepts. A field is a name, a type and optional bounds. `handle` runs only when every field is valid, and reads them as typed getters.

**app/actions/books/create.cr · contract excerpt**

```crystal
contract do
  field title : String, min: 1, max: 200
  field pages : Int32?, min: 1
  field price : Float64, min: 0
  field published : Bool, default: false
  field released_at : Time?
  field cover : Caramel::UploadedFile?
end
```

- `String`: Text as sent; Caramel does not trim it
- `Int32, Int64`: Digits with an optional sign
- `Float64`: A finite decimal, with an optional exponent
- `Bool`: Exactly true or false
- `Time`: RFC 3339 with seconds and a zone, such as 2026-09-30T08:00:00Z; read as UTC
- `Caramel::UploadedFile`: A multipart file part: filename, content_type, path and size
- `Array(T)`: Repeated keys in a form or query (ids=1&ids=2), or a JSON array, of String, Int32, Int64, Float64, Bool, Time or a field value
- `A field value`: A type that includes Caramel::FieldValue(W), such as a SweetTalk value or an aggregate’s id: read as W, then built by its from_field, whose message is the field’s error

Add `?` for a field that may be absent; its getter returns `nil`. `default:` fills an absent field. `min:` and `max:` bound a `String`’s length in characters, and the value of an `Int32`, `Int64` or `Float64`. Bounds on other types, defaults on files and any other type fail compilation. A field value takes no `min:` or `max:`, since its `from_field` checks its own bounds.

An absent value, or text that is only whitespace, is missing. A missing field takes its default, stays `nil` when nilable, and is an error otherwise. An unchecked checkbox sends nothing, so give its `Bool` field `default: false`.

An `Array(T)` field must declare `max:`, the most items it accepts, and may declare `min:`; both count items. It takes no `?` and no default: an absent array is empty. Each item converts like a field of its type, and a blank item is missing. Items keep their order; an item equal to an earlier one is an error.

## Bind each value from one source {#c-routing-binding}

A field binds by name from the route parameters, the body or the query string. The body is a URL-encoded form, a multipart form or a JSON object. There is no precedence between sources: a name sent twice, in one source or across two, is an error unless its field is an Array. `_csrf` and `_method` in a form are transport controls, never fields.

Every submitted key must be a declared field. GET and HEAD queries are the exception, so links can carry tracking or cache-busting parameters. On other methods, an unknown query key is an error too.

A JSON member must have its field’s JSON type: a string for `String` and `Time`, a number for the numeric types, and a boolean for `Bool`. `null` counts as absent. Numbers keep their source text, so `3.5` is not a valid `Int32`. A body that is not an object is an error. In JSON, `_csrf` and `_method` are ordinary members: JSON clients send `X-CSRF-Token` and the real method.

Requests the router cannot read answer before the contract: 400 `Malformed request` for broken encoding or JSON, 413 `Request body is too large` past the route’s limit, and 415 for any other content type. The default limit is 2 MiB of body text; files share a 64 MiB budget. An action’s `ingress` declaration changes the limit, keeps raw bytes, or adds an authenticator that answers 401 before the contract binds.

[Read raw bodies with ingress →](https://caramelize.dev/cookbook/0.14.0/webhooks/index.md)[Send and receive JSON →](https://caramelize.dev/cookbook/0.14.0/return-json/index.md)

## Read the contract errors {#c-routing-errors}

Errors collect per field name. Errors about the request as a whole go under `_base`. These are the English messages:

- `is required`: A missing field with no default that is not nilable
- `must be a valid Int32`: Text that does not convert; also Int64, Float64, Bool and Time
- `must be a JSON string`: A JSON member of the wrong type; also number and boolean
- `must be at least 3 characters`: A String under min:, or over max: with must be at most
- `must be at least 1`: A number under min:, or over max: with must be at most
- `must be a file`: Text sent for an UploadedFile field
- `must have at most 100 item(s)`: An Array over max:, or under min: with must have at least
- `repeats an earlier item`: An item equal to an earlier one, reported under its key, such as ids[2]
- `Duplicate field: title`: Under _base: a name sent more than once
- `Unknown field: extra`: Under _base: a key the contract does not declare
- `Expected a JSON object`: Under _base: a JSON body that is an array or a scalar

An item’s errors use the key `name[index]`, counting from 0, such as `ids[1]`.

A failed contract answers 422, shaped for the client. A client that prefers JSON receives `{"errors": {"page": ["must be a valid Int32"]}}`. A browser or htmx request receives a page titled `Check your request` that lists each error; generated form actions override `contract_failure_page` to re-render the form. Other clients receive plain text:

**Response body · GET /books?page=2&page=3**

```bash
ERR CONTRACT_INVALID:422 at GET /books
FIELD _base: Duplicate field: page
```

With `caramel/i18n`, these messages follow the request’s language.

[Render failures and results →](https://caramelize.dev/docs/0.14.0/actions-and-responses/index.md)

## Link with path helpers {#c-routing-paths}

`Caramel.resource_paths` in `config/paths.cr` defines four helpers. `App::Paths` is included in `ApplicationAction` and `ApplicationView`, so actions and views can call them.

**config/paths.cr**

```crystal
module App::Paths
  Caramel.resource_paths :books, :book
  # Frappé resource paths
end
```

- `books_path`: /books
- `book_path(id : Int64)`: /books/12
- `new_book_path`: /books/new
- `edit_book_path(id : Int64)`: /books/12/edit

An ID must be positive, or the helper raises `ArgumentError`. With locale prefixes enabled, each helper adds the request’s prefix.

## Inspect and repair routes {#c-routing-tools}

`frappe routes` lists every route with its action and contract. A filter keeps routes whose method, path or action contains it, in any case. A field value shows its type and the type it binds from, such as `quantity:Ordering::Quantity(Int32)`. Routes with their own ingress end with a bracketed summary, such as `[raw, 256 KiB, csrf off, authenticate signed?]`.

**Terminal · frappe routes books**

```bash
GET     /books/:id    App::Books::Show  id:Int64(min=1)
PATCH   /books/:id    App::Books::Update  id:Int64(min=1) title:String
```

`frappe check` runs the type check and prints MRDP unless stdout is a terminal. A route without its field becomes a `CONTRACT_MISMATCH` at the contract block, with a `PATCH` line. Inserting that line makes the check pass. A field of the wrong type gets a `FIX` line instead.

**Terminal · frappe check**

```bash
ERR CONTRACT_MISMATCH:422 at app/actions/shelves/show.cr:3:5
NODE: RequestContract
MISSING: id:Int64
PATCH: INSERT "field id : Int64" AT 4:7
```

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Answer the request →](https://caramelize.dev/docs/0.14.0/actions-and-responses/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/routes-and-contracts/
