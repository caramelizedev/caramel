Reference / Security defaults

# Safe by default.

What Caramel checks on every request, and what your application must keep doing.

## Browser writes need a token and an origin {#c-security-csrf}

Caramel checks every POST, PUT, PATCH and DELETE on a route with the default ingress. A request that matches no route is checked too. The `Origin` header must equal the application’s origin exactly. The submitted token must match the `__Host-caramel_csrf` cookie, compared in constant time.

Forms send the token in a hidden `_csrf` field. htmx and `fetch` send it as `X-CSRF-Token`. A JSON member named `_csrf` is not a token. The generated layout puts the header on every htmx request, and generated forms carry the field.

**app/views/layouts/application.cr · generated layout excerpt**

```crystal
body "hx-boost:inherited": "true", "hx-target:inherited": "#content", "hx-swap:inherited": "innerMorph",
  "hx-headers:inherited": {"X-CSRF-Token" => @csrf_token}.to_json do
```

**app/views/books/form.cr · generated form excerpt**

```crystal
form class: "book-form", action: @action, method: "post" do
  input type: "hidden", name: "_csrf", value: @csrf_token
  input type: "hidden", name: "_method", value: @method unless @method == "POST"
```

A token is a timestamp, a random nonce and an HMAC-SHA256 signature. It is valid for 24 hours. Every HTML response sets the cookie with `Secure`, `HttpOnly`, `SameSite=Lax` and `Path=/`. A valid cookie keeps its token; otherwise Caramel issues a new one. A failed check answers 403 with “This form has expired or came from another site. Reload the page and try again.”

`APP_ORIGIN` must be an HTTPS origin without a path. `APP_SECRET` must be at least 32 bytes. A `_method` override reaches a route only when that route reads its body the same way; otherwise the answer is 405.

## Sessions are signed and held by the browser {#c-security-sessions}

`session` is a `Hash(String, String)` stored in the `__Host-caramel_session` cookie. The cookie holds base64url JSON and an HMAC-SHA256 signature. Its key is derived from `APP_SECRET` for this one purpose, so a CSRF signature cannot stand in for a session signature. A cookie that is malformed or wrongly signed reads as an empty session.

**Inside an action · signing in**

```crystal
def handle(contract : Contract) : Caramel::Response
  session["user_id"] = contract.user_id
  redirect_to "/books"
end
```

A response sets the cookie only when the session changed. `sign_out` clears the session, and the response deletes the cookie. The cookie has the same `Secure`, `HttpOnly`, `SameSite=Lax` and `Path=/` attributes. It has no `Max-Age`, so it ends with the browser session. There is no server-side expiry or revocation list. [Revocable sessions →](https://caramelize.dev/cookbook/0.14.0/revocable-sessions/index.md) A session over 4096 bytes raises `Caramel::Session::Overflow`; keep ids in the session and records in the database.

The session is readable, though not editable, by anyone holding the cookie. Store no secrets in it. On a route whose ingress sets `csrf: false`, the session reads empty and is never saved.

## Every response carries the same headers {#c-security-headers}

Caramel adds three headers to every response, including static files and error pages.

- `X-Content-Type-Options: nosniff`: Browsers keep the declared content type
- `Referrer-Policy: same-origin`: Other sites receive no referrer
- `Content-Security-Policy`: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'

The policy blocks inline scripts, inline styles and framing. Put scripts and styles in files under `public/`, as the generated layout does. HTML and JSON responses from actions also send `Cache-Control: no-store`.

The `Host` header must equal the host and port of `APP_ORIGIN`; any other host gets 421 “Unknown project host”. Forwarded headers grant no trust. A path that does not start with `/` gets 400.

## Views escape text and attributes {#c-security-escaping}

Blueprint views escape text and attribute values. The escape covers `&`, `<`, `>`, `"` and `'`. Only `Caramel::HTML::Safe` and Blueprint’s `safe(...)` values are written as they are. `raw` accepts only those values. `markup { … }` builds a small fragment with the same escaping.

**Inside an action · an escaped fragment**

```crystal
morph "#status", with: markup { span { "Status #{count}" } }
```

Wrap a string in `Caramel::HTML::Safe` only when you built or trust all of its HTML. `page(title, body)` with a plain `String` body writes the body as it is, so pass a view or `markup` instead, or escape with `Caramel::HTML.escape`. Escaping protects HTML text and quoted attributes only. It does not make a value safe as a URL, script or style, so validate a stored link before writing it into `href`.

Translated messages keep catalog text as plain text, which the view escapes. When a placeholder value is `Caramel::HTML::Safe`, the message becomes safe HTML: its catalog text and other values are escaped, and only the safe values are written raw. [Translate messages →](https://caramelize.dev/docs/0.14.0/internationalization/index.md)

## Ingress loosens one route at a time {#c-security-ingress}

An action’s `ingress` declaration changes how its route reads the request. Turning CSRF off needs an authenticator. Without one, the build fails with “ingress csrf: false needs authenticate: :method? that verifies a credential a browser does not attach on its own, such as a signature or a bearer token”.

**An action declaration · from Caramel::Action’s documentation**

```crystal
ingress body: :raw,
  limit: 256.kilobytes,
  csrf: false,
  authenticate: :signed?
```

The authenticator runs before the contract binds; false answers 401 “Unauthorized”. `body: :raw` keeps the exact bytes in `raw_body`. A body’s default limit is 2 MiB, and `limit:` sets 1 byte through 64 MiB. A larger body gets 413, and an unsupported media type gets 415. Uploaded files have their own 64 MiB budget, and are stored only for a route whose contract has a `Caramel::UploadedFile` field. A request may send at most 4,096 values and 128 files; more gets 413. A subtype that redeclares ingress must name its parent’s authenticator again. [Receive a signed webhook →](https://caramelize.dev/cookbook/0.14.0/webhooks/index.md)

## Redirects and outbound calls name their destination {#c-security-redirects}

`redirect_to` accepts only a local absolute path. A path starting with `//`, or holding a backslash or control character, raises `ArgumentError`. An htmx request gets 200 with `HX-Location` instead of a 303.

`redirect_external` is the explicit way to another site. It accepts an absolute http or https URL with a host and no credentials, whitespace, control characters or backslashes. Its status must be 301, 302, 303, 307 or 308. The same rule, `Caramel::ExternalURL.valid?`, backs `validate_url` in changesets, so a saved URL can always be redirected to.

**Inside an action · leaving for a stored link**

```crystal
def handle(contract : Contract) : Caramel::Response
  return not_found unless Caramel::ExternalURL.valid?(contract.url)
  redirect_external contract.url
end
```

`Caramel::Outbound.get`, `post` and `request` call third-party APIs under the same URL rule. They connect within 5 seconds and read within 30. The rule does not restrict which host a URL names, so check user-supplied hosts against your own allowlist before calling them.

**Inside an action · an outbound call**

```crystal
headers = HTTP::Headers{"Authorization" => "Bearer #{ENV["API_TOKEN"]}"}
reply = Caramel::Outbound.get("https://api.example.com/status", headers)
```

## Static files stay inside public/ {#c-security-static}

Files in `public/` are served before routing, after the host check. Caramel refuses a path that would leave that directory or reveal a hidden file.

- A malformed percent escape gets 400.
- A decoded path with a NUL byte, a backslash or any segment starting with a dot gets 404. That covers `..`, encoded traversal such as `%2e%2e`, and files such as `.env`.
- A file whose real path, after symbolic links, lies outside `public/` gets 404.
- Methods other than GET and HEAD get 405 with `Allow: GET, HEAD`.

## Errors reveal a reference, not details {#c-security-errors}

An unhandled exception answers 500 “Something went wrong. Reference: …” with an `X-Request-ID` header and `Cache-Control: no-store`. The log records the request id, the error’s class and a fingerprint. Exception messages can hold connection URLs or form values, so they are not logged.

The development error page is compiled only with `-D caramel_development`, which `frappe dev` sets. Even then it appears only when `CARAMEL_ENV` is `development`. It redacts the values of environment variables named like secrets, passwords, tokens, API keys or database URLs, PostgreSQL URLs, and `name=value` credentials. A check builds both modes and confirms the page’s code is absent from the production binary.

> **Your application still owns the rest**
>
> Caramel checks where a request came from, not what the signed-in user may do. Authorization for each record, rate limits, secret storage and the URLs you write into pages stay in your application.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Browse every command →](https://caramelize.dev/docs/0.14.0/commands/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/security/
