Cookbook / Requests and responses

# Read and write JSON.

Use a generated Book resource for browser HTML, JSON responses, and typed JSON input through the same action contracts.

Draft recipe · Target: 0.14.0 · Not yet recipe-tested

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

When `handle` sets `self.etag = book.lock_version`, a successful JSON answer carries `ETag: "3"`. `if_match?(version)` is true when the request has no `If-Match` header, or when it names that version or `*`. Weak tags such as `W/"3"` never match. Answer 412 when it is false.

## Bind a JSON object to the contract {#c-json-input}

The default request policy reads `Content-Type: application/json`. Use a top-level object and the field’s JSON type: strings for String and Time, numbers for Int32, Int64 and Float64, and booleans for Bool. Null is absent. An array binds to an `Array` field; other arrays and objects bind to no field. Duplicate members are errors.

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

Same-origin browser fetch requests send the page’s CSRF token as `X-CSRF-Token`. A JSON member named `_csrf` does not supply that token, and `_method` does not override the HTTP method. Corretto adds the origin, cookie, and CSRF header automatically; override a header to test rejection.

**Corretto · inside a session**

```crystal
forged = {"Accept" => "application/json", "X-CSRF-Token" => "forged"}
client.post("/books", json: book, headers: forged).should have_status(403)
```

## Check the failure cases {#c-json-errors}

When i18n is enabled, contract and changeset error messages use the request’s locale; the JSON `errors` object keeps the same shape. Assert localized messages with an explicit language in your request specs.

Malformed JSON returns 400. A valid JSON value that is not an object returns 422. Wrong field types and contract or changeset errors return 422; JSON clients receive an errors object. Unsupported media types, including `application/*+json`, return 415 under the default policy. An action can use raw ingress when it needs a different JSON format.

**Terminal**

```bash
frappe check
frappe corretto spec/requests/books_spec.cr
```

An `If-Match` that names an old version returns 412, and an update that finds the record changed returns 409.

> **External callers need their own credential**
>
> An API that skips browser CSRF must declare an authenticator with ingress. Its session is empty and unsaved; authenticate with a bearer token or signature that a browser does not attach automatically. The webhook guide shows the request-policy boundary.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Receive a signed body →](https://caramelize.dev/cookbook/0.14.0/webhooks/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/return-json/
