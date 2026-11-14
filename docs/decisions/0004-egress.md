# ADR 0004: An action answers with HTML from Blueprint views, as a fragment only when htmx asks for one

Date: 2026-09-27

Status: accepted.

## Context

An action's answer needs a rule for each client and for the HTML it writes. htmx 4 sends `HX-Request: true` on every request, including those that need the complete document: history restoration, body-targeted boosts and `hx-select`. Views must read like the Crystal around them, with typed inputs, escaped output and compiler errors at the view's own line. An island whose props are JSON interpolated into an attribute by hand works only by accident of the escaping rules.

## Decision

1. **Views are Blueprint classes, and there is no template language.** A view is a Crystal class that takes typed inputs in its constructor and writes its markup as Crystal (`site#c-views-class`). Pages, morphs and partials take views.
2. **Text and attribute values are escaped, and only branded HTML is written raw.** Raw output requires a value of the type that marks trusted HTML. No string is trusted by where it appears.
3. **Blueprint is pinned exactly and patched in one file.** The patch escapes attribute values in full and renders attributes on each call, without Blueprint's attribute cache. A Blueprint upgrade re-verifies the patch.
4. **`HX-Request-Type: partial`, not `HX-Request: true`, selects the fragment.** A page answers with its body alone for a partial request and with the full layout for every other request (`site#c-actions-pages`).
5. **`HX-Request: true` only marks the request as coming from htmx.** An htmx request never receives JSON, and a redirect answers it with an htmx header in place of a redirect status.
6. **JSON answers a client that prefers it, and only when the action returned a value.** A response the action built itself passes through unchanged (`site#c-actions-negotiation`).
7. **A redirect to another site is a separate, explicit call that checks its URL.** The ordinary redirect stays on the site. URL validation on a changeset holds to the same rule, so a saved URL can always be redirected to.
8. **`Caramel::Action` provides a minimal default layout.** Application base actions override it. An action that never renders a page defines no layout.
9. **Islands render through one helper.** The helper validates the component name, serializes typed props to JSON and escapes them for the attribute. A view does not write the island tag by hand.
10. **A morph-aware custom element owns an island's lifecycle.** A morph delivers new props to the mounted component and leaves its client-rendered children alone. The element mounts when it is connected and its component is registered, in either order, and unmounts when it is removed.

## Reasons

- Views are plain Crystal: the compiler proves every expression, errors point at the view's own line, and inputs are typed constructor arguments, not locals looked up by name.
- Escaping by default with a branded type for raw output is the shape of Phlex 2. It makes the unsafe path the one that takes effort.
- The pin is exact because the patch replaces Blueprint internals. The patch is two small overrides in one file.
- Rejected: ECR templates, because they read poorly and look inputs up by name.
- Rejected: Slang, because it is unmaintained, its attribute handling is broken, and its compile errors point at generated code.
- Rejected: Blueprint unpatched, because it escapes attribute values incompletely and its attribute cache is process-wide, unbounded and unlocked.
- `HX-Request-Type` is htmx 4's own signal for the fragment-or-document choice. Answering with the full document whenever the client asks for one keeps boosted navigation, history and `hx-select` correct with no per-action code.
- Rejected: `HX-Request: true` as the fragment signal, because htmx 4 sends it on full-document requests too.
- A returned response means the action chose its egress explicitly, so it is never turned into JSON.
- An htmx header answers an external redirect so that htmx navigates the page instead of fetching the other site.
- Rejected: an abstract `layout`, because an action that streams, morphs, redirects or answers JSON would not compile without one it never uses. The default is a correct, escaped document, not silent misbehaviour, and every generated application replaces it.
- The island helper makes the safe way the only short way: props are serialized and escaped exactly once.
- Leaving an island's children alone lets the server send authoritative props on every morph without destroying client state such as a canvas, a selection or an unsaved drag. This keeps islands compatible with morph-first hypermedia.
- Registration in either order lets application JavaScript load with `defer` and need no bundler.
