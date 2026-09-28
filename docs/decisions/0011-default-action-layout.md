# ADR 0011: `Caramel::Action` provides a minimal default layout

Date: 2026-09-27

Status: accepted. Amends [RFC-0001](../rfc.md) §2.5. [ADR 0018](0018-blueprint-views.md) amends the generated layout: `App::ApplicationAction#layout` renders the `App::Views::Layouts::Application` view in `app/views/layouts/application.cr`, not `application.html.ecr`.

## Context

Every Action inherited an abstract `layout(page) : String`, so any action type without a layout failed to compile. The RFCs' own examples inherit `Caramel::Action` directly: RFC-0003 §2.3's `Boards::Live` and RFC-0008 §2.5's `Subscriptions::Pause`. Neither compiled as written, even though neither ever renders a full page: one streams SSE and the other morphs a region. Generated applications always go through `App::ApplicationAction`, which rendered `app/views/layouts/application.html.ecr`.

## Decision

- `Caramel::Action#layout` has a default: a minimal, valid HTML5 document with an escaped `<title>` from `title_for(page)`, wrapped around the page body.
- Application base actions override it, as the generated `ApplicationAction` does.
- Actions that only stream, morph, redirect or answer JSON need no layout of their own.

## Reasons

- Requiring a layout on types that never render a page is ceremony. Manifesto 8 asks for code "stripped of ceremonial bureaucracy", and the RFC authors wrote their examples without one.
- The fallback is not silent misbehaviour. It is a correct, escaped document, and every generated application replaces it with its own layout.
- Keeping the RFC examples compilable verbatim (`scripts/check cold-brew-compilation`) keeps the specification and the code in agreement. That matters more than one more compile-time obligation.

Principles followed: Manifesto 8 and RFC-0008 §2.5 (single-thought actions: contract, handle, egress).

## Verification

- `spec/caramel/action_spec.cr` checks that an action inheriting `Caramel::Action` directly renders the minimal escaped document for full requests and a bare fragment for `HX-Request-Type: partial`.
- `scripts/check cold-brew-compilation` compiles RFC-0003's `Boards::Live` without scaffolding.
