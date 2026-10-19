# ADR 0037: Response security headers: a configurable Content-Security-Policy, nonces and HSTS

Date: 2026-10-19

Status: accepted.

## Context

`Application#secure` overwrote every response's `Content-Security-Policy` with one constant,
so an application that needs a payment provider's script, an embedded player or an inline
script with a nonce had to put another handler in front of Caramel. Nothing sent
`Strict-Transport-Security`, so a browser that once reached the site over HTTP kept trying
HTTP unless the proxy added the header.

## Decision

1. **Three headers.** Every response carries `X-Content-Type-Options: nosniff`,
   `Referrer-Policy: same-origin` and a `Content-Security-Policy`. The default policy is
   `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'`.
2. **The application's policy.** `Caramel::ContentSecurityPolicy` holds each directive with its
   sources, in order. `Caramel.content_security_policy` is the policy every response carries. An
   application changes it in `config/application.cr`, before the application is built;
   `Application` copies it when it is built.
3. **One response's policy.** `content_security_policy` in an action returns a copy of the
   application's policy that only this response carries. A header an action sets itself is kept
   as it is.
4. **Changing a policy.**
   - `add(directive, *sources)` appends sources and never twice. A `-src` directive the policy
     does not have yet, other than `default-src`, starts from the sources of `default-src`, so
     `add("connect-src", "https://api.example")` keeps `'self'`, which htmx needs. Adding a source
     removes `'none'`. `add` with no source raises `ArgumentError`.
   - `set(directive, *sources)` replaces the directive's sources. With none, it writes the
     directive alone, such as `upgrade-insecure-requests`.
   - `delete(directive)` removes the directive.
   - A directive name that is not lowercase words joined by hyphens, and a source that is not
     printable ASCII without spaces, `,` or `;`, raises `ArgumentError`, so a value cannot end a
     directive or start another.
5. **Nonces.** `csp_nonce` in an action returns a random nonce for this response and adds
   `'nonce-…'` to its `script-src` and `style-src`. The nonce covers only the response that
   carries it, not a fragment htmx swaps into a page loaded earlier, which the page's policy
   governs.
6. **HSTS.** `serve` sends `Strict-Transport-Security: max-age=31536000` on every response when
   `CARAMEL_ENV` is production or unset, and never in development or test. There is no
   `includeSubDomains` and no `preload`, and no setting for either.

## Reasons

- **A policy that applications can change.** The default stays strict, and the exception is
  written where the need is: a response that embeds a player allows that player and no other.
- **Copying from `default-src`.** A `-src` directive that is absent falls back to `default-src`.
  Writing only the new source would make it the whole list and block the origin's own requests.
- **`'none'` gives way.** `'none'` with another source is ignored by browsers, so adding to it
  would silently do nothing.
- **Validation.** A header built from strings is an injection point; the two patterns keep a
  value inside its directive.
- **Per-response nonces.** A nonce that repeats can be replayed. One per response, taken only
  when an action asks, leaves other responses with the strict default.
- **HSTS from `serve`, not the proxy.** The binary knows its environment, and a proxy that
  forgets the header leaves the site downgradable. Development and test use HTTP behind Latte,
  where a pinned HTTPS requirement would lock a browser out of every `*.caramel` host.
- **No `includeSubDomains` or `preload`.** A parent domain may serve sites that are not
  HTTPS-only, and a preload entry is hard to take back.
