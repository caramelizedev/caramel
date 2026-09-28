# ADR 0005: Islands render through `island(name, props)` and a morph-aware custom element

Date: 2026-09-27

Status: accepted. Amends [RFC-0001](../rfc.md) §2.4. [ADR 0018](0018-blueprint-views.md) amends where views are ECR: views are Blueprint classes, and `Caramel::View#island(component, props)` writes the island tag in place.

## Context

RFC-0001 §2.4 shows an island written as raw markup, with the value `props="<%= { … }.to_json %>"`. Caramel templates are compiled ECR that escapes every `<%= %>` interpolation (`src/caramel/view/compiler.cr`). The sketch therefore produces HTML-escaped JSON inside a correctly quoted attribute, and it works only by accident of the escaping rules. The RFC also leaves out three things:

- how client code registers a component;
- what happens when htmx morphs an island;
- how an island is torn down.

## Decision

- Views render islands with the action helper `island("WorkflowCanvas", props)`. It checks that the name is PascalCase and 1 to 64 characters long, serializes `props` to JSON, escapes it for the attribute, and emits `<caramel-island component="…" props="…" hx-morph-skip-children>`. It returns `HTML::Safe`, so the escaping view compiler did not escape it again. Since [ADR 0018](0018-blueprint-views.md), `Caramel::View#island` writes the same tag from a Blueprint view.
- `src/caramel/islands.js`, bundled with every generated application, defines the `<caramel-island>` element and `CaramelIslands.define(name, mount)`.
  - `mount(element, props)` may return nothing, an unmount function, or `{update(props), unmount()}`.
  - An element mounts once it is both connected and registered, in either order. Until then it is `data-island-state="pending"`.
  - A morph that changes `props` calls `update(props)`. `hx-morph-skip-children` makes htmx leave the client-rendered children alone.
  - Removing the element calls `unmount`.
  - Invalid props JSON or a throwing mount sets `data-island-state="error"` and dispatches a bubbling `caramel:island-error` event.

## Reasons

- The helper makes the safe way the only short way. Typed props are serialized and escaped exactly once, and names are validated where the view is compiled and rendered.
- Skipping children lets the server keep sending the authoritative props on every morph without destroying client state such as a canvas, selection or unsaved drag. This keeps the islands escape hatch compatible with morph-first hypermedia.
- Registration in either order means application JavaScript can load with `defer` and needs no bundler.

Principles followed:

- Manifesto 2: the server stays the source of truth, and there is no client state manager or hydration layer.
- Manifesto 8: one readable line in the view.
- RFC-0008 §2.5: egress stays declarative.

## Verification

- `spec/caramel/hypermedia_spec.cr` covers escaping and name validation.
- `scripts/check browser` shows the client lifecycle in Safari: mount with server props, late registration from `pending` to `mounted`, `update` on a props-changing morph with client state intact, and `unmount` on removal.
