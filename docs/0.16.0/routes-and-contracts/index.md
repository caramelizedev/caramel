Reference / Routes and contracts

# Every input, declared.

Map each method and path to one action, and declare the typed fields that action accepts.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | A Caramel application with `config/routes.cr` |
| Covers | Routes, request matching, typed contracts and path helpers |
| Proved by | `frappe routes` · `frappe check` |

Learning it for the first time? The recipe [Create a resource](https://caramelize.dev/cookbook/0.16.0/create-a-resource/index.md) generates the routes and contracts this page describes. This page lists every rule and limit.

## Limits at a glance {#c-routing-limits}

| Limit | Value |
| --- | --- |
| Path segments | 32 |
| Times one parameter name may appear in a path | 1 |
| Values per request | 4,096 |
| Files per request | 128 |
| Body text read by default | 2 MiB |
| Upload budget shared by files | 64 MiB |
| Multipart framing beyond text and uploads | 1 MiB |

## Routes live in one draw block {#c-routing-draw}

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
    get "/books/:id/edit", App::Books::Edit
    patch "/books/:id", App::Books::Update
    delete "/books/:id", App::Books::Destroy
    # Frappé resource routes
  end
end
```

| Path part | Rule |
| --- | --- |
| Start | Begins with `/` |
| Static segment | Letters, digits and `._~-` |
| Parameter | `:snake_case`, such as `:id`; each name appears once per path, and a path may carry several, such as `/teams/:team_id/members/:id` |
| Length | At most 32 segments |

## The compiler checks the route table {#c-routing-checks}

The route table is checked when the application compiles.

| Condition | Outcome |
| --- | --- |
| A line that is not one of the five verbs with a string path and an action constant, such as `resources :books` | fails compilation |
| A malformed path, a repeated parameter or more than 32 segments | fails compilation |
| An action that is undefined, does not inherit from `Caramel::Action`, or has no `contract do … end` block (an empty one is fine) | fails compilation |
| A parameter without a contract field of the same name | fails compilation |
| A parameter field that is not a non-nilable `String`, `Int32` or `Int64`, or a field value bound from one, without `default:` | fails compilation |
| Two routes that match the same requests (`DUPLICATE ROUTE`) | fails compilation |
| A static route declared after a parameter route that would catch it (`AMBIGUOUS ROUTE ORDER`) | fails compilation |
| One `tenant App::Model, by: :field do … end` block, with `caramel/tenancy` required | groups the routes inside it under the tenant’s address |
| A second `tenant` block, one without `caramel/tenancy`, a route outside it that starts with a parameter, or a route inside it whose first segment a central route also uses | fails compilation; [Multi-tenancy](https://caramelize.dev/docs/0.16.0/multi-tenancy/index.md) shows the block |

Declare `/books/new` before `/books/:id`. A missing field names the route, the contract block and the fix:

**Compiler output · excerpt, paths shortened**

```bash
❌ ROUTE CONTRACT MISMATCH
Route: '/books/:book_id' defines parameter ':book_id'
Action: 'App::Books::Show::Contract' is missing 'field book_id : Type'
  --> config/routes.cr:9:5
Contract: app/actions/books/show.cr:3:5
Remediation: add `field book_id : Int64` to the contract block of App::Books::Show.
```

## Static segments win over parameters {#c-routing-matching}

Static segments win over parameters, and matching backtracks. `GET /books/new` reaches `New`, and `GET /teams/new/members` can still reach `/teams/:team_id/members`. Empty segments never match a parameter, so `/books/` is not `/books`.

| Condition | Outcome |
| --- | --- |
| No route at the path | answers 404 with `Not found` |
| A route at the path with another method | answers 405 with `Method not allowed` and an `Allow` header, such as `GET, HEAD, PATCH` |
| A HEAD request to a GET route | runs it, drops the body, keeps the headers and sets `Content-Length` |
| A HEAD request to a streamed response | omits `Content-Length` |
| A route parameter that fails its field (`field id : Int64, min: 1`: `/books/abc`, `/books/0`) | answers 404 |
| A path over 32 segments | answers 404 |
| A malformed path escape, an escape that decodes to `/`, `\` or a control byte, or a raw backslash or control byte in the path | answers 400 with `Malformed path` |
| A route parameter whose decoded bytes are not UTF-8 | answers 400 with `Malformed request` |

HTML forms can only send GET and POST.

| Condition | Outcome |
| --- | --- |
| A POST form whose `_method` is `PATCH`, `PUT` or `DELETE`, in any case | routes as that method |
| Any other `_method` value | answers 400 |
| A target route that reads its body differently, for example through its own `ingress` | answers 405 |
| A JSON body with `_method` | does not override; send the real method |

## Every action declares a contract {#c-routing-contract}

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

| Type | Accepts |
| --- | --- |
| `String` | Text as sent; Caramel does not trim it |
| `Int32, Int64` | Digits with an optional sign |
| `Float64` | A finite decimal, with an optional exponent |
| `Bool` | Exactly true or false |
| `Time` | RFC 3339 with seconds and a zone, such as 2026-09-30T08:00:00Z; read as UTC |
| `Caramel::UploadedFile` | A multipart file part: filename, content_type, path and size |
| `Array(T)` | Repeated keys in a form or query (ids=1&ids=2), or a JSON array, of String, Int32, Int64, Float64, Bool, Time or a field value |
| `A field value` | A type that includes Caramel::FieldValue(W), such as a SweetTalk value or an aggregate’s id: read as W, then built by its from_field, whose message is the field’s error |

| Condition | Outcome |
| --- | --- |
| `?` on a field | getter returns `nil` when absent |
| `default:` | fills an absent field |
| `min:` or `max:` on a `String` | bound its length in characters |
| `min:` or `max:` on `Int32`, `Int64` or `Float64` | bound its value |
| Bounds on other types, defaults on files, any other type | fails compilation |
| `min:` or `max:` on a field value (its `from_field` checks its own bounds) | fails compilation |
| An absent value, or text that is only whitespace | counts as missing |
| A missing field with a default | takes the default |
| A missing nilable field | stays `nil` |
| A missing field with neither | answers 422 with `is required` under the field |

An unchecked checkbox sends nothing, so give its `Bool` field `default: false`.

| Condition | Outcome |
| --- | --- |
| An `Array(T)` field without `max:` | fails compilation |
| An `Array(T)` field with `?` or a default | fails compilation |
| `min:` or `max:` on an Array that is not an integer literal, or with `min:` below 0, `max:` below 1 or `min:` above `max:` | fails compilation |
| `min:` and `max:` on an Array | count items |
| An absent array | is empty |
| A blank item | answers 422 with `is required` under `name[index]` |
| An item equal to an earlier one | answers 422 with `repeats an earlier item` under `name[index]` |
| Items | keep their order |
| Each item | converts like a field of its type |

## Each value binds from one source {#c-routing-binding}

A field binds by name from the route parameters, the body or the query string. The body is a URL-encoded form, a multipart form or a JSON object.

| Condition | Outcome |
| --- | --- |
| A name sent twice, in one source or across two | answers 422 with `Duplicate field: name` under `_base` |
| The same name for an `Array` field | binds every item |
| `_csrf` or `_method` in a form | is a transport control, never a field |
| A submitted key the contract does not declare | answers 422 with `Unknown field: name` under `_base` |
| An undeclared key in the query of a GET or HEAD request | is ignored, so links can carry tracking or cache-busting parameters |
| An undeclared query key on other methods | answers 422 with `Unknown field: name` under `_base` |
| A JSON member of the wrong JSON type (a string for `String` and `Time`, a number for the numeric types, a boolean for `Bool`, an array for `Array(T)`) | answers 422 with `must be a JSON string`, `number`, `boolean` or `array` under the field |
| `null` in JSON | counts as absent |
| A JSON number such as `3.5` for an `Int32` (numbers keep their source text) | answers 422 with `must be a valid Int32` under the field |
| A JSON body that is not an object | answers 422 with `Expected a JSON object` under `_base` |
| `_csrf` and `_method` in JSON | are ordinary members; send `X-CSRF-Token` and the real method |
| Broken encoding or JSON | answers 400 `Malformed request` |
| A body past the route’s limit, more than 4,096 values (every query and form pair, JSON member, JSON array item and multipart part counts as one), more than 128 file parts, or a multipart body that spends more than 1 MiB on boundaries and part headers beyond its text and uploads | answers 413 `Request body is too large` |
| Any other content type | answers 415 |
| An `ingress` authenticator that answers false | answers 401 before the contract binds |

The default limit is 2 MiB of body text; files share a 64 MiB budget. An action’s `ingress` declaration changes the limit, keeps raw bytes, or adds an authenticator.

[Read raw bodies with ingress →](https://caramelize.dev/cookbook/0.16.0/webhooks/index.md)[Send and receive JSON →](https://caramelize.dev/cookbook/0.16.0/return-json/index.md)

## Contract errors collect per field {#c-routing-errors}

Errors collect per field name. Errors about the request as a whole go under `_base`. These are the English messages:

| Message | When it appears |
| --- | --- |
| `is required` | A missing field with no default that is not nilable |
| `must be a valid Int32` | Text that does not convert; also Int64, Float64, Bool and Time |
| `must be a JSON string` | A JSON member of the wrong type; also number, boolean and, for an Array field, array |
| `must be at least 3 characters` | A String under min:, or over max: with must be at most |
| `must be at least 1` | A number under min:, or over max: with must be at most |
| `must be a file` | Text sent for an UploadedFile field |
| `must have at most 100 item(s)` | An Array over max:, or under min: with must have at least |
| `repeats an earlier item` | An item equal to an earlier one, reported under its key, such as ids[2] |
| `Duplicate field: title` | Under _base: a name sent more than once |
| `Unknown field: extra` | Under _base: a key the contract does not declare |
| `Expected a JSON object` | Under _base: a JSON body that is an array or a scalar |

An item’s errors use the key `name[index]`, counting from 0, such as `ids[1]`.

| Condition | Outcome |
| --- | --- |
| A failed contract | answers 422, shaped for the client |

A client that prefers JSON receives `{"errors": {"page": ["must be a valid Int32"]}}`. Other clients receive plain text:

**Response body · GET /books?page=2&page=3**

```bash
ERR CONTRACT_INVALID:422 at GET /books
FIELD _base: Duplicate field: page
```

With `caramel/i18n`, these messages follow the request’s language.

[Render failures and results →](https://caramelize.dev/docs/0.16.0/actions-and-responses/index.md)

## Path helpers build links {#c-routing-paths}

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

| Condition | Outcome |
| --- | --- |
| A name given to `resource_paths` that is not a lowercase identifier (`[a-z][a-z0-9_]*`) | fails compilation |
| An ID that is not positive | raises ArgumentError |
| Locale prefixes enabled | each helper adds the request’s prefix |
| `caramel/tenancy` required | each helper adds the request tenant’s prefix; [Multi-tenancy](https://caramelize.dev/docs/0.16.0/multi-tenancy/index.md) shows the addresses |

Prove it

## Inspect and repair routes {#c-routing-tools}

These commands assume the Book resource of [Your first application](https://caramelize.dev/docs/0.16.0/getting-started/index.md), step 02; generate it first. `frappe routes` lists every route with its action and contract. A filter keeps routes whose method, path or action contains it, in any case. A field value shows its type and the type it binds from, such as `quantity:Ordering::Quantity(Int32)`. Routes with their own ingress end with a bracketed summary, such as `[raw, 256 KiB, csrf off, authenticate signed?]`.

**Terminal · inside the application**

```bash
frappe routes books
```

**Expect:** Prints one line per route whose method, path or action contains `books`, in any case, seven for a generated Book: method, path, action, then the contract fields. The show route’s line reads `GET /books/:id App::Books::Show id:Int64(min=1)`.

`frappe check` runs the type check and prints MRDP unless stdout is a terminal. A route without its field becomes a `CONTRACT_MISMATCH` at the contract block, with a `PATCH` line when `contract do` ends its line. Inserting that line makes the check pass. A field of the wrong type gets a `FIX` line instead.

**Terminal · inside the application**

```bash
frappe check
```

**Expect:** Exits 0 and prints `OK check N files` when piped, `✓ Type check passed` on a terminal. A route without its field becomes a `CONTRACT_MISMATCH` at the contract block, with a `PATCH` line; inserting that line makes the check pass.

**Output · frappe check, a route without its field**

```bash
ERR CONTRACT_MISMATCH:422 at app/actions/shelves/show.cr:3:5
NODE: RequestContract
MISSING: id:Int64
PATCH: INSERT "field id : Int64" AT 4:7
```

**Passing:** `frappe check` exits 0 once every route parameter has its contract field, and `frappe routes books` lists each Book route with its contract fields.

[← Production](https://caramelize.dev/docs/0.16.0/deployment/index.md) · [Answer the request →](https://caramelize.dev/docs/0.16.0/actions-and-responses/index.md)

Caramel 0.16.0 · https://caramelize.dev/docs/0.16.0/routes-and-contracts/
