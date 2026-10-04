# ADR 0011: `Caramel::Action` provides a minimal default layout

Date: 2026-09-27

Status: accepted. Amended by ADR 0018.

## Context

An Action with an abstract `layout(page) : String` forces every action type to define a layout, even those that never render a full page: one streams SSE, another morphs a region. Generated applications go through `App::ApplicationAction`, which supplies the application's layout.

## Decision

- `Caramel::Action#layout` has a default: a minimal, valid HTML5 document with an escaped `<title>` from `title_for(page)`, wrapped around the page body.
- Application base actions override it, as the generated `ApplicationAction` does. ADR 0018 states the generated layout.
- Actions that only stream, morph, redirect or answer JSON need no layout of their own.

## Reasons

- Requiring a layout on types that never render a page is ceremony.
- The fallback is not silent misbehaviour. It is a correct, escaped document, and every generated application replaces it with its own layout.
- Rejected: an abstract `layout`, because actions that never render a page would not compile without it, and a usage example inheriting `Caramel::Action` directly must compile as written (`scripts/check cold-brew-compilation`).
- Actions stay single-thought: contract, handle, egress.
