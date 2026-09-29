# ADR 0020: Actions declare how their route reads the request, and form routes bind JSON objects

Date: 2026-09-29

Status: accepted. Amends [ADR 0003](0003-core-routing-and-contracts.md) decisions 3 and 4, and [RFC-0001](../rfc.md) §3.

## Context

ADR 0003 read every request the same way before routing. `Caramel::RequestInput` accepted URL-encoded and multipart forms, answered any other media type with 415, and the application checked CSRF on every POST, PUT, PATCH and DELETE. First users of 0.4.0 hit that boundary twice:

- **JSON clients** ([#2](https://github.com/caramelizedev/caramel/issues/2)). A notes API had to reopen `RequestInput` to parse JSON into contract fields. Its first version changed form parsing for the whole application.
- **Signed webhooks** ([#3](https://github.com/caramelizedev/caramel/issues/3)). A webhook relay needs the exact bytes it received to verify an HMAC, a limit of its own, and an authentication policy in place of the browser CSRF check. It had to reopen `Application#handle` for one path.

A token-authenticated JSON API has the same needs as the webhook, except that it wants its body parsed rather than raw.

## Decision

1. **Declaration.** An action may declare `ingress body:, limit:, csrf:, authenticate:`, beside its contract. Each keyword is optional.
   - `body: :form` is the default. `body: :raw` keeps the body exactly as sent, of any content type, as `raw_body : Bytes`.
   - `limit:` is an integer, `N.kilobytes` or `N.megabytes`, from 1 byte to 64 MiB. The default is 2 MiB.
   - `csrf: false` skips the browser CSRF check.
   - `authenticate: :method?` names an instance method returning `Bool`.

   Everything is checked at compile time: unknown or positional keywords, non-literal values, limits out of range, a second declaration in one type, `raw_body` on a form action, an authenticator that does not exist or does not return `Bool`, and `csrf: false` without `authenticate:`.

   An action inherits its parent's ingress, so an API base declares it once, and a subtype's own declaration replaces it.
2. **Routing before reading.** `Application#handle` asks the router for a `Router::Match` on the request's real method (HEAD as GET) and path before it reads the body.
   - The matched route's ingress decides how the body is read and whether CSRF is checked.
   - A request that matches no route, or matches on another method, reads and is checked with the default ingress. A route's CSRF setting therefore never applies to a request it did not match.
   - The same match drives dispatch, so the trie is walked once unless the request overrides its method. Matching still allocates nothing.
3. **Reading.** `RequestInput.read(request, ingress)` reads under the policy.
   - **Raw.** The bytes are read up to the limit, with no transport controls, and the contract binds only the route and the query.
   - **Form.** URL-encoded text and multipart text are bounded by the limit; uploads keep their 64 MiB budget. `application/json` bodies are also read (rule 4).
   - Other media types still answer 415.
4. **JSON.** A JSON body must be an object. Its scalar members bind like form fields:
   - numbers keep their source text, so contracts convert them with the existing grammar;
   - `null` is absent;
   - a duplicate member is an error, and the first value wins;
   - a member must have its field's JSON type (a string for `String` and `Time`, a number for `Int32`, `Int64` and `Float64`, a boolean for `Bool`), or the field reports `must be a JSON number` or similar;
   - nested arrays and objects bind to no field.

   A body that is not an object answers 422 with `Expected a JSON object`. Malformed JSON, trailing data, NUL and invalid UTF-8 answer 400. `_csrf` and `_method` are ordinary members: JSON clients send `X-CSRF-Token` and use real methods. `+json` media types are not read as JSON, because their conventions for `null` and nesting mean something this binding would silently change; such routes use `body: :raw`.
5. **CSRF.** Body methods are CSRF-checked unless the matched route declares `csrf: false`, which requires an authenticator. Same-origin `fetch` passes the token in `X-CSRF-Token`, as htmx does.
   - On a CSRF-off route the session reads empty and is never saved. Another site's form carries the browser's cookies, so only a credential a browser does not attach on its own, such as a signature or a bearer token, may stand in for the check.
6. **Authentication.** The authenticator runs after the body is read and before the contract binds. False answers 401 with no detail, so an unauthenticated caller learns nothing from contract errors. It runs for every method of its route, reads included.
7. **Method overrides.** A POST form's `_method` reaches a route only when that route reads its body like the POST's policy: form body, same limit, same CSRF setting. Otherwise the answer is 405. An override therefore never skips a check, and a raw route never parses `_method`.
8. **Listing.** `routes` (and `frappe routes`) prints a route's non-default ingress, such as `[raw, 256 KiB, csrf off, authenticate signed?]`.

## Reasons

- The policy that guards a route belongs next to the code that verifies its credential, where a compile error can insist that turning CSRF off names a verifier.
- The body must be read differently per route (raw bytes, a limit), so the route has to be known before the body is read. Matching on the real method, and falling back to the default policy, keeps every unmatched request as guarded as before.
- JSON members bind through the same contract grammar as form text, so a JSON client and a form share one contract and one set of error messages. Checking each member's JSON type keeps `"5"` from passing as a number.
- An empty session on CSRF-off routes turns the one authenticator that would reopen CSRF, a session cookie, into one that fails closed.

Principles followed:

- Manifesto 7: compile-time AST macros replace runtime reflection.
- Manifesto 3: no hidden allocation on the matching path.
- RFC-0008 §2.5: an action reads as contract, handle and egress, with no plumbing.

## Verification

- `spec/caramel/request_input_spec.cr` covers:
  - JSON scalars and their types;
  - `null`, duplicates, nesting, a non-object body, malformed JSON, NUL and invalid UTF-8;
  - the ingress limit;
  - raw bytes of any type, with no transport controls;
  - 415 for other media types.
- `spec/caramel/request_contract_spec.cr` covers JSON binding and type errors.
- `spec/caramel/ingress_spec.cr` covers:
  - an HMAC-signed webhook without CSRF;
  - 401 before the action or the contract;
  - 413 over the limit;
  - a token API whose session is empty and unsaved;
  - authenticated reads;
  - same-origin JSON requiring the CSRF header;
  - no CSRF bypass through unmatched routes or other methods;
  - 405 for an override into a route that reads differently;
  - the route listing.
- `spec/caramel/router_spec.cr` covers matching by the real method before the body, with zero allocation.
- `scripts/check route-compilation` covers every compile error above, plus an inherited and a redeclared ingress.
