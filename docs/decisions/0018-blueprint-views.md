# ADR 0018: Views are Blueprint classes

Date: 2026-09-28

Status: accepted. Amends [ADR 0005](0005-island-props-helper.md) and [ADR 0011](0011-default-action-layout.md) where they name ECR.

## Context

Views need to read like the Crystal around them, with typed inputs, escaped output and compiler errors at the view's own line. Compiled ECR templates (`.html.ecr`) read poorly and look inputs up by name. Slang is unmaintained and its attribute handling is broken, and Blueprint 1.1.0, a Phlex-style shard that writes HTML in plain Crystal, escapes attribute values incompletely and caches attributes in an unbounded, unlocked process-wide hash.

## Decision

1. **Views are Blueprint classes.** `shard.yml` depends on `blueprint` pinned exactly to 1.1.0; its license is `vendor/licenses/blueprint-LICENSE`. `abstract class Caramel::View` (`src/caramel/view.cr`) includes `Blueprint::HTML`. A view takes typed inputs in `initialize` and writes its markup in `private def blueprint`. A view renders once.
2. **Text and attribute values are escaped.** `src/caramel/view.cr` reopens `Blueprint::HTML::AttributesRenderer`: attribute values get the same five-character HTML escape as text (`&`, `<`, `>`, `"`, `'`; the stdlib `HTML.escape` and `Caramel::HTML.escape` escape the same set), and attributes render per call, without Blueprint's attribute cache.
3. **Trusted HTML is branded.** `Caramel::HTML::Safe` includes `Blueprint::SafeObject` (`src/caramel/html.cr`), so it is written as-is in text and attribute values, as are Blueprint's `safe(...)` values. Nothing else is.
4. **The pin is exact** because the patch replaces Blueprint internals. A Blueprint upgrade must re-verify the patch; `spec/caramel/view_spec.cr` guards it.
5. **Naming.** `app/views/<dir>/<name>.cr` defines `App::Views::<Dir>::<Name>`.
6. **Egress takes views.** `page(title, view)` renders a view as the page; `morph(target, with: view)` and `Caramel::Partial.new(target, view.to_s)` take views (`src/caramel/action.cr`). `Caramel::View#island(component, props)` writes an island tag ([ADR 0005](0005-island-props-helper.md)) in place. `markup { … }` builds a fragment too small for a view class with a view's escaping, as `Caramel::HTML::Safe` for `morph(target, with: …)` or `page(title, …)`.
7. **Generated applications** (`frappe new`, `templates/application`):
   - `app/views/application_view.cr` defines `abstract class App::ApplicationView < Caramel::View`, which includes `App::Paths`.
   - The layout is `App::Views::Layouts::Application.new(page : Caramel::Page, csrf_token)` in `app/views/layouts/application.cr`, rendered by `App::ApplicationAction#layout` ([ADR 0011](0011-default-action-layout.md)). It writes the body with `raw @page.html`: `Caramel::Page#html` is the rendered body as `Caramel::HTML::Safe`.
   - `app/views/home/index.cr` is `App::Views::Home::Index`.
   - `config/application.cr` requires `../app/views/application_view`, then `../app/views/**`, before the actions.
   - `.ameba.yml` globs `app/**/*.cr` and excludes `app/views/**/*.cr` from `Lint/DebugCalls`: in a view, `p` is the paragraph element, not the debug print.
8. **`frappe make resource`** (`templates/resource`, `src/frappe/resource_generator.cr`) writes `app/views/<plural>/{index,show,new,edit,form}.cr` as `App::Views::<Plural>::{Index,Show,New,Edit,Form}`. The Form takes `(action, method, csrf_token, values, errors)`; New and Edit render the Form they are given. Each field the form takes, which is every field not declared `name:type:server`, is `labelled "name", "Label" do |id| ... end` around an explicit `input` or `select_tag`. Actions call, for example, `page "Books", Views::Books::Index.new(result[:records])`. `ApplicationView` is a reserved resource name and `views` a reserved plural.
9. **ECR is gone, without a deprecation release:** there are no ECR views, `Caramel::View.render` or `embed`, `view "..."` lookup macro (`Caramel::Templates`), or ECR compiler. View errors are ordinary Crystal errors at the view's own file and line. This is an explicit exception to the deprecation rule in `CONTRIBUTING.md`, because the only ECR applications were demos.

## Reasons

- Views are plain Crystal: the compiler proves every expression, and errors point at the view's own line.
- Inputs are typed constructor arguments, not locals looked up by name.
- Text is escaped, and raw output requires a safe-branded value, the shape of Phlex 2.
- Patching Blueprint is two small overrides in one file, pinned and specified.
- Rejected: keeping ECR, because it reads poorly and looks inputs up by name.
- Rejected: Slang 1.7.3, because it is unmaintained since 2021, its lexer ends an attribute value at the first space, it escapes only `"` in dynamic attributes, and its compile errors point at generated code.
- Rejected: Blueprint unpatched, because attribute values would round-trip `&amp;` as `&`, and the attribute cache grows without bound and is unlocked without `-Dpreview_mt`.
