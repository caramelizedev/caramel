# ADR 0004: `HX-Request-Type: partial`, not `HX-Request: true`, selects fragment egress

Date: 2026-09-27

Status: accepted. Amends [RFC-0001](../rfc.md) §2.5.

## Context

RFC-0001 §2.5 says that a request carrying `HX-Request: true` receives the compiled HTML fragment. The vendored htmx 4.0.0 (`vendor/htmx/htmx-4.0.0.min.js`) sends `HX-Request: true` on every request it issues. It also sends `HX-Request-Type`:

- `full` when the swap target is `document.body` or the request uses `hx-select`;
- `partial` otherwise.

History restoration, body-targeted boosts and `hx-select` requests all need the complete document. If they received a fragment, they would drop the layout's `<head>`, assets and navigation.

## Decision

- `RequestContext#partial?` is true exactly when `HX-Request-Type: partial` is present.
- `Action#page` returns the page body with its `<title>` for a partial request, which htmx extracts, and the full layout otherwise.
- `HX-Request: true` alone still marks the request as coming from htmx, and it has two effects:
  - htmx requests never negotiate JSON;
  - `redirect_to` answers with `HX-Location` instead of a 303.
- Responses vary on `Accept, HX-Request, HX-Request-Type`.
- JSON egress applies when the client prefers `application/json` by q-value, does not send `HX-Request`, and `handle` returned a value rather than a `Caramel::Response`. A returned `Response` (`page`, `morph`, `partials`, `redirect_to`, `stream`) means the action chose its egress explicitly, so it passes through unchanged.

## Reasons

- The header the RFC names cannot tell a fragment request from a full-document request under htmx 4, the engine the RFC mandates. `HX-Request-Type` is htmx 4's own signal for exactly this choice.
- Returning a full document whenever the client asks for one keeps boosted navigation, history and `hx-select` correct with no per-action code.

Principles followed:

- Manifesto 2: state lives in the database and the hypermedia. The server must answer each hypermedia request in the form the client needs.
- RFC-0008 §2.5: egress is one line in the action, and negotiation stays invisible.

## Verification

- `spec/caramel/action_spec.cr` covers fragments versus full pages, JSON negotiation and `HX-Location` redirects.
- The generated `spec/requests/home_spec.cr` and resource request specs cover full and partial responses (`scripts/check frappe-project`).
- `scripts/check browser` shows in Safari that htmx-issued swaps receive fragments and never nest a second layout.
