# ADR 0004: An action answers with HTML from Blueprint views, as a fragment only when htmx sends `HX-Request-Type: partial`

Date: 2026-09-27

Status: accepted.

## Context

An action's answer needs a rule for each client and for the HTML it writes.

- **Fragment or document.** The vendored htmx 4.0.0 (`vendor/htmx/htmx-4.0.0.min.js`) sends `HX-Request: true` on every request it issues, so that header cannot tell a fragment request from a full-document request. It also sends `HX-Request-Type`: `full` when the swap target is `document.body` or the request uses `hx-select`, and `partial` otherwise. History restoration, body-targeted boosts and `hx-select` requests need the complete document; a fragment would drop the layout's `<head>`, assets and navigation.
- **Views.** Views need to read like the Crystal around them, with typed inputs, escaped output and compiler errors at the view's own line. Compiled ECR templates (`.html.ecr`) read poorly and look inputs up by name. Slang is unmaintained and its attribute handling is broken. Blueprint 1.1.0, a Phlex-style shard that writes HTML in plain Crystal, escapes attribute values incompletely and caches attributes in an unbounded, unlocked process-wide hash.
- **Layout.** An action with an abstract `layout(page) : String` forces every action type to define a layout, even those that never render a full page: one streams SSE, another morphs a region. Generated applications go through `App::ApplicationAction`, which supplies the application's layout.
- **Islands.** An island written as raw markup with a `props` attribute that holds interpolated JSON produces HTML-escaped JSON inside a quoted attribute, and works only by accident of the escaping rules. Three things need a defined contract: how client code registers a component, what happens when htmx morphs an island, and how an island is torn down.

## Decision

The rules an application relies on are stated on the website ([site.html](../../website/source/site.html)), chiefly its Views and Actions and responses references, in the sections cited below by anchor, and in the doc comments under [src/caramel](../../src/caramel). This record states what was chosen.

1. **Views are Blueprint classes.** `abstract class Caramel::View` (`src/caramel/view.cr`) includes `Blueprint::HTML`; a view takes typed inputs in `initialize`, writes its markup in `private def blueprint` and renders once (`site#c-views-class`, `View`). `app/views/<dir>/<name>.cr` defines `App::Views::<Dir>::<Name>`. There is no template language beside it: no ECR view, `Caramel::View.render`, `embed`, `view "..."` lookup macro (`Caramel::Templates`) or ECR compiler exists. A view error is an ordinary Crystal error at the view's own file and line.
2. **Text and attribute values are escaped, and only branded HTML is written raw.** Attribute values get the same five-character escape as text; the stdlib `HTML.escape` and `Caramel::HTML.escape` escape the same set (`site#c-views-attributes`, `site#c-security-escaping`). `Caramel::HTML::Safe` includes `Blueprint::SafeObject` (`src/caramel/html.cr`), so it is written as-is in text and attribute values, as are Blueprint's `safe(...)` values. Nothing else is (`site#c-views-composing`).
3. **Blueprint is pinned exactly and patched in one file.** `shard.yml` depends on `blueprint` pinned exactly to 1.1.0; its license is `vendor/licenses/blueprint-LICENSE`. `src/caramel/view.cr` reopens `Blueprint::HTML::AttributesRenderer` to escape attribute values and to render attributes per call, without Blueprint's attribute cache (the comment on that reopening says what Blueprint did). A Blueprint upgrade must re-verify the patch (`site#c-releases-dependencies`); `spec/caramel/view_spec.cr` guards it.
4. **Egress takes views.** `page(title, view)` renders a view as the page; `morph(target, with: view)` and `Caramel::Partial.new(target, view.to_s)` take views (`src/caramel/action.cr`, `Partial`). `markup { … }` builds a fragment too small for a view class with a view's escaping, as `Caramel::HTML::Safe` for `morph(target, with: …)` or `page(title, …)` (`site#c-views-markup`, `site#c-actions-pages`, `site#c-actions-regions`).
5. **`HX-Request-Type: partial`, not `HX-Request: true`, selects the fragment.** `RequestContext#partial?` is true exactly when `HX-Request-Type: partial` is present. `Action#page` returns the page body with its `<title>` for a partial request, which htmx extracts, and the full layout otherwise (`site#c-actions-pages`).
6. **`HX-Request: true` alone marks the request as coming from htmx.** It has two effects: an htmx request never negotiates JSON, and a redirect answers with an htmx header in place of a redirect status, `HX-Location` for `redirect_to` and `HX-Redirect` for `redirect_external` (`site#c-actions-negotiation`, `site#c-actions-redirects`).
7. **JSON answers a client that prefers it, and only when `handle` returned a value.** JSON egress applies when the client prefers `application/json` by q-value, does not send `HX-Request`, and `handle` returned a value rather than a `Caramel::Response`. A returned `Response` (`page`, `morph`, `partials`, `redirect_to`, `stream`) passes through unchanged (`site#c-actions-shape`, `site#c-actions-negotiation`, `Action#respond`). Responses vary on `Accept, HX-Request, HX-Request-Type`. A JSON answer carries a version as an `ETag`, and `if_match?(version)` compares `If-Match` strongly, so an action answers 412 to a stale version (`site#c-actions-json`, `Action#etag=`, `Action#if_match?`).
8. **A redirect to another site is explicit and checks its URL.** `redirect_external` refuses anything but an absolute http or https URL without credentials and a redirect status, and `cs.validate_url` holds to the same rule (`ExternalURL`, `site#c-actions-redirects`, `site#c-security-redirects`).
9. **`Caramel::Action` provides a minimal default layout.** `Caramel::Action#layout` has a default: a minimal, valid HTML5 document with an escaped `<title>` from `title_for(page)`, wrapped around the page body. Application base actions override it, as the generated `ApplicationAction` does. Actions that only stream, morph, redirect or answer JSON need no layout of their own (`site#c-actions-pages`, `Action#layout`).
10. **Islands render through `island(name, props)`.** `island("WorkflowCanvas", props)` checks that the name is PascalCase and 1 to 64 characters long, serializes `props` to JSON, escapes it for the attribute, and emits `<caramel-island component="…" props="…" hx-morph-skip-children>` as `Caramel::HTML::Safe` (`Island`, `site#c-views-composing`). `Caramel::View#island(component, props)` writes the tag in place.
11. **A morph-aware custom element owns an island's lifecycle.** `src/caramel/islands.js`, bundled with every generated application, defines the `<caramel-island>` element and `CaramelIslands.define(name, mount)` (`site#c-islands-mount`).
    - `mount(element, props)` may return nothing, an unmount function, or `{update(props), unmount()}`.
    - An element mounts once it is both connected and registered, in either order. Until then it is `data-island-state="pending"`, and once mounted it is `data-island-state="mounted"`.
    - A morph that changes `props` calls `update(props)`. `hx-morph-skip-children` makes htmx leave the client-rendered children alone.
    - Removing the element calls `unmount`.
    - Invalid props JSON or a throwing mount sets `data-island-state="error"` and dispatches a bubbling `caramel:island-error` event.
12. **A generated application starts with a base view, a layout view and a home view.** `frappe new` (`templates/application`) writes:
    - `app/views/application_view.cr`, which defines `abstract class App::ApplicationView < Caramel::View` and includes `App::Paths`;
    - `app/views/layouts/application.cr`, the layout `App::Views::Layouts::Application.new(page : Caramel::Page, csrf_token)`, rendered by `App::ApplicationAction#layout`. It writes the body with `raw @page.html`: `Caramel::Page#html` is the rendered body as `Caramel::HTML::Safe` (`site#c-views-layout`);
    - `app/views/home/index.cr`, which is `App::Views::Home::Index`;
    - `config/application.cr`, which requires `../app/views/application_view`, then `../app/views/**`, before the actions;
    - `.ameba.yml`, which globs `app/**/*.cr` and excludes `app/views/**/*.cr` from `Lint/DebugCalls` (the application rule set is in [ADR 0017](0017-style-and-checks.md)).
13. **`frappe make resource` writes five views.** The generator (`templates/resource`, `src/frappe/resource_generator.cr`) writes `app/views/<plural>/{index,show,new,edit,form}.cr` as `App::Views::<Plural>::{Index,Show,New,Edit,Form}`. The Form takes `(action, method, csrf_token, values, errors)`; New and Edit render the Form they are given. Each field the form takes, which is every field not declared `name:type:server`, is `labelled "name", "Label" do |id| ... end` around an explicit `input` or `select_tag` (`site#c-views-forms` shows `labelled`). Actions call, for example, `page "Books", Views::Books::Index.new(result[:records])`. `ApplicationView` is a reserved resource name and `views` a reserved plural.

## Reasons

- Views are plain Crystal: the compiler proves every expression, and errors point at the view's own line.
- Inputs are typed constructor arguments, not locals looked up by name.
- Text is escaped, and raw output requires a safe-branded value, the shape of Phlex 2.
- Patching Blueprint is two small overrides in one file, pinned and specified. The pin is exact because the patch replaces Blueprint internals.
- Rejected: keeping ECR, because it reads poorly and looks inputs up by name.
- Rejected: Slang 1.7.3, because it is unmaintained since 2021, its lexer ends an attribute value at the first space, it escapes only `"` in dynamic attributes, and its compile errors point at generated code.
- Rejected: Blueprint unpatched, because attribute values would round-trip `&amp;` as `&`, and the attribute cache grows without bound and is unlocked without `-Dpreview_mt`.
- `HX-Request-Type` is htmx 4's own signal for the fragment-or-document choice.
- Returning a full document whenever the client asks for one keeps boosted navigation, history and `hx-select` correct with no per-action code.
- Rejected: `HX-Request: true` as the fragment signal, because htmx 4 sends it on full-document requests too.
- A returned `Response` means the action chose its egress explicitly, so it is never turned into JSON.
- `redirect_external` answers htmx with `HX-Redirect` so that htmx navigates the page rather than fetching the other site.
- Requiring a layout on types that never render a page is ceremony.
- The fallback layout is not silent misbehaviour. It is a correct, escaped document, and every generated application replaces it with its own layout.
- Rejected: an abstract `layout`, because actions that never render a page would not compile without it, and a usage example inheriting `Caramel::Action` directly must compile as written (`scripts/check cold-brew-compilation`).
- Actions stay single-thought: contract, handle, egress.
- The `island` helper makes the safe way the only short way. Typed props are serialized and escaped exactly once, and names are validated where the view is rendered.
- Skipping children lets the server keep sending the authoritative props on every morph without destroying client state such as a canvas, selection or unsaved drag. This keeps the islands escape hatch compatible with morph-first hypermedia.
- Registration in either order means application JavaScript can load with `defer` and needs no bundler.
- Views are excluded from `Lint/DebugCalls` because in a view `p` is the paragraph element, not the debug print.
