# ADR 0018: Views are Blueprint classes

Date: 2026-09-28

Status: accepted. Amends [RFC-0008](../rfc.md) §2.4, RFC-0001's presentation text (the partials example in §2.3, the island example in §2.4 and the layout in §2.5), and [ADR 0005](0005-island-props-helper.md) and [ADR 0011](0011-default-action-layout.md) where they name ECR.

## Context

RFC-0008 §2.4 adopts Slang, a whitespace-sensitive template language. Caramel shipped compiled ECR views instead: `.html.ecr` files under `app/views/`, looked up with the `view "books/show"` macro (`Caramel::Templates`), rendered by `Caramel::View.render`/`embed`, and compiled by an adaptation of Crystal's ECR processor (`src/caramel/view/compiler.cr`, Apache-2.0, `vendor/licenses/crystal-LICENSE`) that escaped every `<%= %>` expression. `scripts/check views` tested that its errors pointed back at the template. After comparing a generated form written in ECR and in Blueprint, the owner rejected ECR for how it reads.

Slang 1.7.3 was evaluated on Crystal 1.21.0:

- Its last release was in May 2021. The library code has not changed since, and open pull requests are unmerged.
- Its lexer ends an attribute value at the first space, so RFC-0008 §2.4's own example does not compile: `class=(team.active? ? … : …)` and `hx-vals='{"seats": 1}'` both fail.
- Dynamic attribute values escape only `"` (`src/slang/nodes/element.cr:36`).
- Compile errors point at its generated code: a typo on line 3 of `typo.slang` was reported at line 15 of the generated Crystal. Issue #27, location pragmas, has been open since 2017.

Blueprint 1.1.0 (github.com/stephannv/blueprint), a Phlex-style shard that writes HTML in plain Crystal, was evaluated as well. It had two defects Caramel cannot ship:

- Attribute values escaped only `"` (`src/blueprint/html/attributes_renderer.cr:64`), so `&` reached the browser raw and a stored `&amp;` came back as `&`.
- Attributes rendered through a process-wide cache (lines 4-23): a `Hash(UInt64, String)` keyed by the attributes' 64-bit hash, never evicted, and locked only under `-Dpreview_mt`.

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
9. **Removed, without a deprecation release:** ECR views, `Caramel::View.render` and `embed`, the `view "..."` lookup macro (`Caramel::Templates`), `src/caramel/view/compiler.cr` with `vendor/licenses/crystal-LICENSE`, and `scripts/check views`. View errors are now ordinary Crystal errors at the view's own file and line, so the ECR location mapping that check tested no longer exists.

This is an explicit exception to the deprecation rule in `CONTRIBUTING.md`. The owner chose a clean cutover because the only ECR applications are demos.

## Reasons

- Views are plain Crystal: the compiler proves every expression, and errors point at the view's own line. A typo in a probe view was reported at `typo.cr:12:27`.
- Inputs are typed constructor arguments, not locals looked up by name.
- Text is escaped, and raw output requires a safe-branded value. This is the shape of Phlex 2 (phlex.fun), which renders selectively through an explicit `fragment` and whose `raw` only outputs strings branded with `safe`.
- Slang would have needed the RFC's example rewritten to compile, a patch to its attribute escaping and location mapping it has lacked since 2017, in a library that is no longer maintained.
- Patching Blueprint is two small overrides in one file, pinned and specified.

Principles followed:

- Manifesto 8 and RFC-0008 §1: markup that reads like the code around it.
- Manifesto 7: the compiler checks every view, and reports errors at the view's own line to people and agents alike.

## Alternatives considered

- **Keep ECR.** Rejected by the owner for how it reads.
- **Slang 1.7.3.** Rejected for the reasons in Context.
- **Blueprint unpatched.** Rejected: attribute values would round-trip `&amp;` as `&`, and the attribute cache grows without bound and is unlocked without `-Dpreview_mt`.

## Verification

- `spec/caramel/view_spec.cr`: attribute escaping round trip, `Safe` as-is in text and attributes, nested views, the island helper, and no retained attribute cache.
- `spec/caramel/action_spec.cr`: a page from a view with escaped input and a nested view, and a `markup` fragment that escapes its text and attributes and calls the action's own method.
- `spec/frappe/resource_generator_spec.cr` and `spec/frappe/new_project_spec.cr`: generated views and configuration.
- `scripts/check frappe-project`: a generated application with Book and Person resources covering every field kind compiles, lints and passes its request specs.
- `scripts/check browser`: the probe application's views (`spec/fixtures/browser/app/views/probe/*.cr`) in Safari.
- `scripts/check all`.

## Implementation

- Framework: `src/caramel/view.cr`, `src/caramel/html.cr`, `src/caramel/action.cr`, `src/caramel/hypermedia.cr`, `shard.yml`, `vendor/licenses/blueprint-LICENSE`, `THIRD_PARTY_NOTICES.md`.
- Generator: `templates/application`, `templates/resource`, `src/frappe/resource_generator.cr`.
- Checks: the browser probe views and the benchmarks are ported. The edit-latency benchmark's `template` kind is now `view`, and inserts a `comment` marker into `app/views/home/index.cr`; `compiler-profile`'s stage is `view_edit`.
