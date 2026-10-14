Reference / Security defaults

# Safe by default.

What Caramel checks on every request, and what your application must keep doing.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | `APP_ORIGIN` as an HTTPS origin without a path; `APP_SECRET` of at least 32 bytes |
| Covers | CSRF, sessions, headers, escaping, ingress, redirects, static files, errors |
| Proved by | `frappe corretto`: forged requests answer 403 |

Learning it for the first time? [Best practices](https://caramelize.dev/docs/0.15.0/best-practices/index.md) shows which protections to keep on. This page lists every default.

## Limits at a glance {#c-security-limits}

| Limit | Value |
| --- | --- |
| CSRF token valid for | 24 hours |
| `APP_SECRET`, at least | 32 bytes |
| Session cookie, at most | 4096 bytes |
| Default request body | 2 MiB |
| `limit:` range | 1 byte – 64 MiB |
| Uploaded files budget | 64 MiB |
| Values and files per request | 4,096 values, 128 files |
| Outbound call | 5 s connect, 30 s read |

## Browser writes need a token and an origin {#c-security-csrf}

The submitted token must match the `__Host-caramel_csrf` cookie, compared in constant time.

| Condition | Outcome |
| --- | --- |
| POST, PUT, PATCH or DELETE on a route with the default ingress | checked |
| A request that matches no route | checked too |
| `Origin` that does not equal the application’s origin exactly | answers 403 |
| A token that does not match the `__Host-caramel_csrf` cookie | answers 403 |
| A failed check | answers 403 “This form has expired or came from another site. Reload the page and try again.” |
| A JSON member named `_csrf` | is not a token |
| A valid cookie | keeps its token |
| No valid cookie | a new token is issued |
| `APP_ORIGIN` that is not an HTTPS origin without a path | raises ArgumentError |
| `APP_SECRET` under 32 bytes | raises ArgumentError |
| A `_method` override on a route that reads its body differently | answers 405 |

Forms send the token in a hidden `_csrf` field. htmx and `fetch` send it as `X-CSRF-Token`. The generated layout puts the header on every htmx request, and generated forms carry the field.

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

A token is a timestamp, a random nonce and an HMAC-SHA256 signature. Every HTML response sets the cookie with `Secure`, `HttpOnly`, `SameSite=Lax` and `Path=/`.

## Sessions are signed and held by the browser {#c-security-sessions}

`session` is a `Hash(String, String)` stored in the `__Host-caramel_session` cookie. The cookie holds base64url JSON and an HMAC-SHA256 signature. Its key is derived from `APP_SECRET` for this one purpose.

**Inside an action · signing in**

```crystal
def handle(contract : Contract) : Caramel::Response
  session["user_id"] = contract.user_id
  redirect_to "/books"
end
```

| Condition | Outcome |
| --- | --- |
| A cookie that is malformed or wrongly signed | reads as an empty session |
| A CSRF signature offered as a session signature | does not verify, because the key is derived for one purpose |
| A response when the session did not change | sets no cookie |
| `sign_out` | clears the session; the response deletes the cookie |
| A session over 4096 bytes | raises `Caramel::Session::Overflow` |
| A route whose ingress sets `csrf: false` | reads an empty session and never saves it |

The cookie has the same `Secure`, `HttpOnly`, `SameSite=Lax` and `Path=/` attributes. It has no `Max-Age`, so it ends with the browser session. There is no server-side expiry or revocation list. [Revocable sessions →](https://caramelize.dev/cookbook/0.15.0/revocable-sessions/index.md) Keep ids in the session and records in the database.

The session is readable, though not editable, by anyone holding the cookie. Store no secrets in it.

## Every response carries the same headers {#c-security-headers}

Caramel adds three headers to every response, including static files and error pages.

| Header | Effect |
| --- | --- |
| `X-Content-Type-Options: nosniff` | Browsers keep the declared content type |
| `Referrer-Policy: same-origin` | Other sites receive no referrer |
| `Content-Security-Policy` | `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'` |

| Condition | Outcome |
| --- | --- |
| Inline scripts, inline styles and framing | blocked by the policy |
| HTML and JSON responses from actions | also send `Cache-Control: no-store` |
| `Host` that differs from `APP_ORIGIN`’s host and port | answers 421 “Unknown project host” |
| Forwarded headers | grant no trust |
| A path that does not start with `/` | answers 400 |

Put scripts and styles in files under `public/`, as the generated layout does.

## Views escape text and attributes {#c-security-escaping}

Blueprint views escape text and attribute values. The escape covers `&`, `<`, `>`, `"` and `'`. `markup { … }` builds a small fragment with the same escaping.

| Condition | Outcome |
| --- | --- |
| A `Caramel::HTML::Safe` or `safe(...)` value | written as it is |
| `raw` with any other value | fails compilation |
| `page(title, body)` with a plain `String` body | written as it is; pass a view or `markup` instead, or escape with `Caramel::HTML.escape` |
| A value used as a URL, script or style | not made safe by escaping; validate a stored link before writing it into `href` |
| A translated message with a `Caramel::HTML::Safe` placeholder | becomes safe HTML: its catalog text and other values are escaped, and only the safe values are written raw |
| A translated message otherwise | catalog text stays plain text, which the view escapes |

**Inside an action · an escaped fragment**

```crystal
morph "#status", with: markup { span { "Status #{count}" } }
```

Wrap a string in `Caramel::HTML::Safe` only when you built or trust all of its HTML. Escaping protects HTML text and quoted attributes only. [Translate messages →](https://caramelize.dev/docs/0.15.0/internationalization/index.md)

## Ingress loosens one route at a time {#c-security-ingress}

An action’s `ingress` declaration changes how its route reads the request. Turning CSRF off needs an authenticator.

**An action declaration · from Caramel::Action’s documentation**

```crystal
ingress body: :raw,
  limit: 256.kilobytes,
  csrf: false,
  authenticate: :signed?
```

| Condition | Outcome |
| --- | --- |
| `csrf: false` without `authenticate:` | fails compilation with “ingress csrf: false needs authenticate: :method? that verifies a credential a browser does not attach on its own, such as a signature or a bearer token” |
| A subtype that redeclares `ingress` without its parent’s authenticator | fails compilation |
| An authenticator that returns false | answers 401 “Unauthorized”, before the contract binds |
| A body over its limit | answers 413 |
| An unsupported media type | answers 415 |
| More than 4,096 values or 128 files | answers 413 |
| `body: :raw` | keeps the exact bytes in `raw_body` |
| Uploaded files | stored only for a route whose contract has a `Caramel::UploadedFile` field |

A body’s default limit is 2 MiB, and `limit:` sets 1 byte through 64 MiB. Uploaded files have their own 64 MiB budget. A request may send at most 4,096 values and 128 files. [Receive a signed webhook →](https://caramelize.dev/cookbook/0.15.0/webhooks/index.md)

## Redirects and outbound calls name their destination {#c-security-redirects}

`redirect_to` accepts only a local absolute path. `redirect_external` is the explicit way to another site: it accepts an absolute http or https URL with a host and no credentials, whitespace, control characters or backslashes.

| Condition | Outcome |
| --- | --- |
| `redirect_to` with a path starting `//`, or holding a backslash or control character | raises ArgumentError |
| `redirect_to` from an htmx request | answers 200 with `HX-Location` instead of 303 |
| `redirect_external` with a URL that is not absolute http or https with a host, or that holds credentials, whitespace, control characters or backslashes | raises ArgumentError |
| `redirect_external` with a status other than 301, 302, 303, 307 or 308 | raises ArgumentError |
| A URL saved with `validate_url` | can always be redirected to, because `Caramel::ExternalURL.valid?` backs both |
| A user-supplied host in `Caramel::Outbound` | not restricted by the rule; check it against your own allowlist |

**Inside an action · leaving for a stored link**

```crystal
def handle(contract : Contract) : Caramel::Response
  return not_found unless Caramel::ExternalURL.valid?(contract.url)
  redirect_external contract.url
end
```

`Caramel::Outbound.get`, `post` and `request` call third-party APIs under the same URL rule. They connect within 5 seconds and read within 30.

**Inside an action · an outbound call**

```crystal
headers = HTTP::Headers{"Authorization" => "Bearer #{ENV["API_TOKEN"]}"}
reply = Caramel::Outbound.get("https://api.example.com/status", headers)
```

## Static files stay inside public/ {#c-security-static}

Files in `public/` are served before routing, after the host check. Caramel refuses a path that would leave that directory or reveal a hidden file.

| Condition | Outcome |
| --- | --- |
| A malformed percent escape | answers 400 |
| A decoded path with a NUL byte, a backslash or any segment starting with a dot, such as `..`, encoded traversal like `%2e%2e`, or `.env` | answers 404 |
| A file whose real path, after symbolic links, lies outside `public/` | answers 404 |
| A method other than GET and HEAD | answers 405 with `Allow: GET, HEAD` |

## Errors reveal a reference, not details {#c-security-errors}

| Condition | Outcome |
| --- | --- |
| An unhandled exception | answers 500 “Something went wrong. Reference: …” with an `X-Request-ID` header and `Cache-Control: no-store` |
| The exception message | is not logged, because it can hold connection URLs or form values; the log keeps the request id, the error’s class and a fingerprint |
| A build without `-D caramel_development` | holds none of the error page’s code; a check builds both modes and confirms it |
| A development build run without `CARAMEL_ENV=development` | shows no error page |

The development error page is compiled only with `-D caramel_development`, which `frappe dev` sets. It redacts the values of environment variables named like secrets, passwords, tokens, API keys or database URLs, PostgreSQL URLs, and `name=value` credentials.

> Not covered **Your application still owns the rest**
>
> Caramel checks where a request came from, not what the signed-in user may do. Authorization for each record, rate limits, secret storage and the URLs you write into pages stay in your application.

Prove it

## Prove the defaults {#c-security-prove}

**Terminal · inside the application**

```bash
frappe corretto spec/requests/books_spec.cr
```

**Passing:** Every example passes. The generated spec’s forged `X-CSRF-Token` and foreign `Origin` requests answer 403, and its sample title `<title>` is checked as escaped text.

[← Crema](https://caramelize.dev/docs/0.15.0/crema/index.md) · [Browse every command →](https://caramelize.dev/docs/0.15.0/commands/index.md)

Caramel 0.15.0 · https://caramelize.dev/docs/0.15.0/security/
