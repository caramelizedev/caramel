# ADR 0023: Blueprint-shaped expectations inspect rendered HTML

Date: 2026-09-30

Status: accepted. Extends [ADR 0010](0010-corretto-harness.md) and
[RFC-0006](../rfc.md#rfc-0006-caramel-corretto-zero-mock-integration-testing).

## Context

Raw HTML substring assertions couple behavioral specs to quote style, attribute
order and escaping spelling. They also let unrelated elements satisfy a check.
Blueprint gives views a readable Crystal vocabulary, but rendering an expected
view through the same code would hide renderer defects.

## Framework comparison

| Framework | Existing approach | Lesson for Corretto |
| --- | --- | --- |
| [Rails](https://guides.rubyonrails.org/testing.html#testing-views) | Nested DOM assertions for selected requirements, with separate structural equality assertions. | Scope nested requirements to a matched ancestor; distinguish partial requirements from equality. |
| [Laravel](https://laravel.com/framework/docs/13.x/http-tests#testing-views) | Fluent response and Blade-component assertions, including text and ordered text checks. | Readability matters, but text presence alone does not prove element structure. |
| [Phoenix LiveView](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveViewTest.html) | Element selectors and text filters over rendered output. | Assert observable rendered content and scope it explicitly. |
| [Phlex](https://www.phlex.fun/components/testing) | Parses rendered components into HTML5 documents or fragments for richer assertions. | A familiar view DSL need not be the assertion engine; use a real parser. |
| [Lucky](https://luckyframework.org/guides/testing/html-and-interactivity) | Crystal assertions with scoped browser elements. | Keep Crystal syntax readable; retain browser tests for interactive behavior. |

These are design precedents, not imported execution models. Corretto continues
to drive in-process application requests against real database branches.

## Decision

Add `have_html(within: nil, count: nil, strict: false) { … }` and a block overload
of `render_partial(target, swap:)`. Both accept one root requirement. Reuse
Blueprint 1.1.0's standard element declarations with Corretto registration
macros, recording text and attributes without rendering them. Explicit
`element("custom-tag")` supports custom elements; unknown standard methods fail
compilation. Keep existing matcher signatures.

Use [Lexbor 3.6.4](https://github.com/kostya/lexbor/tree/v3.6.4), pinned as a
development dependency in the framework and generated applications, and required
only through Corretto. Application lockfiles retain the explicit development pin;
production installs neither fetch nor build the parser. Its existing HTML5
parser decodes attributes and text, and handles document and fragment parsing.
An internal adapter owns native documents, chooses table/select fragment
contexts, validates selectors and frees memory after each assertion. There is
no global DOM cache. Dependency installation now needs `cc`, `ar` and network
access for Lexbor's verified native source download.

Default patterns select requirements: extra markup, wrappers and attributes are
allowed; siblings are unordered but must match distinct nodes within the same
ancestor. Strings check exact decoded descendant text after HTML whitespace
normalization, preserving preformatted whitespace. `plain` checks direct text.
Classes match a token subset; booleans assert presence or absence. Strict mode
compares complete attributes and ordered direct-child structure, ignoring
comments and insignificant whitespace. Counts apply to complete matching roots;
negation inverts the full result. Invalid expectations, selectors and missing
scopes raise instead of making negative assertions pass.

Production-case and authoring checks extend leaf text to numeric, Boolean and
character results. Other leaf values require explicit `.to_s` and raise if
unsupported; empty collection loops add no text. Conditional attribute arrays
flatten and omit `nil`. Direct text coalesces across comments in both modes.
Boolean attributes retain presence/absence syntax; ARIA/data literal false
values use strings. See the [case inventory](../research/corretto-html-testing.md).

Parse response matchers too: partial target, swap and content must come from the
same element. Full pages need an actual source doctype and a parsed title;
title matching retains substring semantics. Failure diagnostics retain paths,
observed values/counts and bounded excerpts after releasing the document.

Before DOM parsing, token metadata renames actual `hx-partial` envelopes to
templates, matching htmx's treatment of table/select payloads. The adapter moves
their parsed content into restored envelope nodes without adding wrappers.
Ordinary template content remains inert. Lexbor's shard does not expose native
template content, so a private binding follows the pinned C layout; review it
when upgrading that dependency. Raw text and comments are never envelopes.

Migrate behavioral specs and generated examples to decoded element assertions.
Keep exact byte tests for serialization/escaping and browser checks for actual
htmx morphing. Teach Caramel's Ameba runner to recognize `p` and nested braces
only inside expectation blocks, preserving debug lint elsewhere. The existing
line limit stays unchanged.

## Manifesto alignment

- **2, state in database and hypermedia:** assertions inspect response HTML.
- **3, expose the machine:** the native parser, install requirements and ownership
  are explicit; production installs and ordinary application binaries do not gain
  a parser dependency.
- **5, no tautological mocks:** expected nodes are independent data, never
  application view invocations or rerendered expected HTML. Escaping mutations
  must fail. Browser morph verification remains a separate boundary.
- **7, compile-time clarity:** Blueprint's finite vocabulary catches misspellings;
  runtime failures identify the expectation path and observed content.
- **8, poetic syntax:** requirements read like the project's views, with one
  familiar vocabulary and no redundant selector-and-markup language.

## Alternatives

Rendering a second Blueprint tree would risk shared escaping defects. Raw text
helpers improve spelling but cannot establish ancestry. A homegrown HTML parser
would repeat mature HTML5 parsing machinery. Browser-only assertions are still
needed for interactions but add unnecessary process overhead to request specs.
CSS remains useful for `within:` without becoming a second complete public DSL.

## Verification

`spec/corretto/html_spec.cr` covers matching semantics, escaping mutation,
fragment contexts, scoping and diagnostics. Compiler fixtures cover captured
locals, loops and invalid element names. `scripts/check lint` proves paragraph
and brace exceptions stay scoped. Action, view and generated-resource specs
exercise real rendered responses. `scripts/check frappe-project` installs and
checks a generated application; `scripts/check all` includes browser morphing.
See [the testing guide](../testing.md) for the complete matching contract.
