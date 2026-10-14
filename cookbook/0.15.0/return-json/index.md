Cookbook / Requests and responses

# Read and write JSON.

Use a generated Book resource for browser HTML, JSON responses, and typed JSON input through the same action contracts.

Draft recipe · Target: 0.15.0 · Not yet recipe-tested

| Contract | Value |
| --- | --- |
| Needs | A generated Book resource, as in [Create a resource](https://caramelize.dev/cookbook/0.15.0/create-a-resource/index.md) |
| You will have | HTML and JSON answers from the same actions, typed JSON input, CSRF-protected browser writes, and checks for each failure status |
| Proved by | `frappe corretto spec/requests/books_spec.cr` |

## Where the change goes {#c-json-files}

- `app/actions/books/`: ETag and If-Match handling
- `spec/requests/books_spec.cr`: JSON request examples

## Ask for a JSON response {#c-json-response}

A generated action returns records from `handle` and supplies HTML through `render`. A client sending `Accept: application/json` receives the action result as JSON.

**spec/requests/books_spec.cr · inside an example**

```crystal
Corretto.session do |client, db|
  response = client.get("/books",
    headers: {"Accept" => "application/json"})
  response.should have_status(200)
  JSON.parse(response.body)["records"].as_a.should be_empty
end
```

This example assumes an empty spec database. Add a persisted-book case to verify the returned fields.

When `handle` sets `self.etag = book.lock_version`, a successful JSON answer carries `ETag: "3"`. Answer 412 when `if_match?(version)` is false.

| Condition | Outcome |
| --- | --- |
| No `If-Match` header | `if_match?(version)` is true |
| `If-Match` names that version or `*` | `if_match?(version)` is true |
| Weak tag such as `W/"3"` | never matches |

## Bind a JSON object to the contract {#c-json-input}

The default request policy reads `Content-Type: application/json`. Use a top-level object.

| JSON value | Binds to |
| --- | --- |
| string | A String or Time field |
| number | An Int32, Int64 or Float64 field |
| boolean | A Bool field |
| null | Absent |
| array | An `Array` field |
| any other array, or an object | No field |
| duplicate member | An error |

**spec/requests/books_spec.cr · inside an example**

```crystal
Corretto.session do |client, db|
  book = {title: "Dune", author: "Frank Herbert"}
  accept = {"Accept" => "application/json"}
  created = client.post("/books", json: book, headers: accept)
  created.should have_status(201)
  JSON.parse(created.body)["record"]["title"].as_s.should eq("Dune")
end
```

## Keep browser writes protected {#c-json-csrf}

Same-origin browser fetch requests send the page’s CSRF token as `X-CSRF-Token`. Corretto adds the origin, cookie, and CSRF header automatically; override a header to test rejection.

| Condition | Outcome |
| --- | --- |
| A JSON member named `_csrf` | does not supply the token |
| A JSON member named `_method` | does not override the HTTP method |
| A forged `X-CSRF-Token` header | answers 403 |

**Corretto · inside a session**

```crystal
forged = {"Accept" => "application/json", "X-CSRF-Token" => "forged"}
client.post("/books", json: book, headers: forged).should have_status(403)
```

## Check the failure cases {#c-json-errors}

When i18n is enabled, contract and changeset error messages use the request’s locale; the JSON `errors` object keeps the same shape. Assert localized messages with an explicit language in your request specs.

| Condition | Outcome |
| --- | --- |
| Malformed JSON | answers 400 |
| A valid JSON value that is not an object | answers 422 |
| Wrong field types | answers 422; JSON clients receive an errors object |
| Contract or changeset errors | answers 422; JSON clients receive an errors object |
| Unsupported media type, including `application/*+json`, under the default policy | answers 415 |
| `If-Match` names an old version | answers 412 |
| An update finds the record changed | answers 409 |

An action can use raw ingress when it needs a different JSON format.

> **External callers need their own credential**
>
> An API that skips browser CSRF must declare an authenticator with ingress. Its session is empty and unsaved; authenticate with a bearer token or signature that a browser does not attach automatically. The webhook guide shows the request-policy boundary.

Prove it

## Prove the JSON behavior {#c-json-prove}

**Terminal · inside the application**

```bash
frappe check
frappe corretto spec/requests/books_spec.cr
```

**Passing:** Every JSON example passes: the list answers 200 with an empty `records`, the create answers 201 with the title, and the forged token answers 403.

> Draft **Written for 0.15.0, not yet run end to end.**
>
> The recipe keeps its Draft label until it has been run from a new application to a passing spec.

[← All recipes](https://caramelize.dev/cookbook/0.15.0/) · [Receive a signed body →](https://caramelize.dev/cookbook/0.15.0/webhooks/index.md)

Caramel 0.15.0 · https://caramelize.dev/cookbook/0.15.0/return-json/
