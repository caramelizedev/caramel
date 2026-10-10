# ADR 0004: `HX-Request-Type: partial`, not `HX-Request: true`, selects fragment egress

Date: 2026-09-27

Status: accepted.

## Context

The vendored htmx 4.0.0 (`vendor/htmx/htmx-4.0.0.min.js`) sends `HX-Request: true` on every
request it issues, so that header cannot tell a fragment request from a full-document request.
It also sends `HX-Request-Type`: `full` when the swap target is `document.body` or the request
uses `hx-select`, and `partial` otherwise. History restoration, body-targeted boosts and
`hx-select` requests need the complete document; a fragment would drop the layout's `<head>`,
assets and navigation.

## Decision

1. `RequestContext#partial?` is true exactly when `HX-Request-Type: partial` is present.
2. `Action#page` returns the page body with its `<title>` for a partial request, which htmx extracts, and the full layout otherwise.
3. `HX-Request: true` alone still marks the request as coming from htmx, and it has two effects:
   - htmx requests never negotiate JSON;
   - `redirect_to` answers with `HX-Location` instead of a 303. `redirect_external`, which sends the browser to another site, answers with `HX-Redirect` instead of a `Location` redirect, so htmx navigates the page rather than fetching that site.
4. Responses vary on `Accept, HX-Request, HX-Request-Type`.
5. JSON egress applies when the client prefers `application/json` by q-value, does not send `HX-Request`, and `handle` returned a value rather than a `Caramel::Response`. A returned `Response` (`page`, `morph`, `partials`, `redirect_to`, `stream`) means the action chose its egress explicitly, so it passes through unchanged. A JSON answer carries `ETag: "N"` when `handle` set `self.etag = N`, and `if_match?(version)` evaluates `If-Match` with strong comparison, so an action answers 412 to a stale version.
6. `redirect_external` refuses anything but an absolute http or https URL without credentials and a redirect status; other clients receive `Location`. `cs.validate_url` holds to the same rule.

## Reasons

- `HX-Request-Type` is htmx 4's own signal for the fragment-or-document choice.
- Returning a full document whenever the client asks for one keeps boosted navigation, history and `hx-select` correct with no per-action code.
- Rejected: `HX-Request: true` as the fragment signal, because htmx 4 sends it on full-document requests too.
