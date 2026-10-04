# ADR 0005: Islands render through `island(name, props)` and a morph-aware custom element

Date: 2026-09-27

Status: accepted. Decision 1 is amended by [ADR 0018](0018-blueprint-views.md).

## Context

An island written as raw markup with `props="<%= { … }.to_json %>"` produces HTML-escaped JSON
inside a quoted attribute, and works only by accident of the escaping rules. Three things need
a defined contract:

- how client code registers a component;
- what happens when htmx morphs an island;
- how an island is torn down.

## Decision

1. Views render islands with `island("WorkflowCanvas", props)`. It checks that the name is PascalCase and 1 to 64 characters long, serializes `props` to JSON, escapes it for the attribute, and emits `<caramel-island component="…" props="…" hx-morph-skip-children>` as `HTML::Safe`. Views are Blueprint classes (ADR 0018), and `Caramel::View#island(component, props)` writes the tag in place.
2. `src/caramel/islands.js`, bundled with every generated application, defines the `<caramel-island>` element and `CaramelIslands.define(name, mount)`.
   - `mount(element, props)` may return nothing, an unmount function, or `{update(props), unmount()}`.
   - An element mounts once it is both connected and registered, in either order. Until then it is `data-island-state="pending"`, and once mounted it is `data-island-state="mounted"`.
   - A morph that changes `props` calls `update(props)`. `hx-morph-skip-children` makes htmx leave the client-rendered children alone.
   - Removing the element calls `unmount`.
   - Invalid props JSON or a throwing mount sets `data-island-state="error"` and dispatches a bubbling `caramel:island-error` event.

## Reasons

- The helper makes the safe way the only short way. Typed props are serialized and escaped exactly once, and names are validated where the view is rendered.
- Skipping children lets the server keep sending the authoritative props on every morph without destroying client state such as a canvas, selection or unsaved drag. This keeps the islands escape hatch compatible with morph-first hypermedia.
- Registration in either order means application JavaScript can load with `defer` and needs no bundler.
