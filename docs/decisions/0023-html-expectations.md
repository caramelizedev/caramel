# ADR 0023: Blueprint-shaped expectations inspect rendered HTML

Date: 2026-09-30

Status: accepted. Extends [ADR 0010](0010-corretto-harness.md).

## Context

Raw HTML substring assertions couple behavioral specs to quote style, attribute
order and escaping spelling. They also let unrelated elements satisfy a check.
Blueprint gives views a readable Crystal vocabulary, but rendering an expected
view through the same code would hide renderer defects.

## Decision

1. Corretto provides `have_html(within: nil, count: nil, strict: false) { … }` and a
   block overload of `render_partial(target, swap:)`. Both accept one root
   requirement. They reuse Blueprint 1.1.0's standard element declarations with
   Corretto registration macros, recording text and attributes without rendering
   them. Explicit `element("custom-tag")` supports custom elements; unknown
   standard methods fail compilation. Existing matcher signatures are unchanged.
2. The parser is [Lexbor 3.6.4](https://github.com/kostya/lexbor/tree/v3.6.4),
   pinned as a development dependency in the framework and generated applications,
   and required only through Corretto. Application lockfiles retain the explicit
   development pin; production installs neither fetch nor build the parser.
   Its HTML5 parser decodes attributes and text, and handles document and
   fragment parsing. An internal adapter owns native documents, chooses
   table/select fragment contexts, validates selectors and frees memory after
   each assertion. There is no global DOM cache. Dependency installation needs
   `cc`, `ar` and network access for Lexbor's verified native source download.
3. Default patterns select requirements: extra markup, wrappers and attributes
   are allowed; siblings are unordered but must match distinct nodes within the
   same ancestor. Strings check exact decoded descendant text after HTML
   whitespace normalization, preserving preformatted whitespace. `plain` checks
   direct text. Classes match a token subset; booleans assert presence or
   absence. Strict mode compares complete attributes and ordered direct-child
   structure, ignoring comments and insignificant whitespace. Counts apply to
   complete matching roots; negation inverts the full result. Invalid
   expectations, selectors and missing scopes raise instead of making negative
   assertions pass.
4. Leaf text accepts numeric, Boolean and character results. Other leaf values
   need explicit `.to_s` and raise if unsupported; empty collection loops add no
   text. Conditional attribute arrays flatten and omit `nil`. Direct text
   coalesces across comments in both modes. Boolean attributes keep
   presence/absence syntax; ARIA/data literal false values use strings. The
   [case inventory](https://github.com/caramelizedev/caramel-notes/blob/main/research/corretto-html-testing.md)
   lists the cases.
5. Response matchers parse too: partial target, swap and content must come from
   the same element. Full pages need an actual source doctype and a parsed
   title; title matching keeps substring semantics. Failure diagnostics keep
   paths, observed values/counts and bounded excerpts after releasing the
   document.
6. Before DOM parsing, token metadata renames actual `hx-partial` envelopes to
   templates, matching htmx's treatment of table/select payloads. The adapter
   moves their parsed content into restored envelope nodes without adding
   wrappers. Ordinary template content stays inert. Lexbor's shard does not
   expose native template content, so a private binding follows the pinned C
   layout; review it when upgrading that dependency. Raw text and comments are
   never envelopes.
7. Behavioral specs and generated examples use decoded element assertions.
   Exact byte tests remain for serialization/escaping, and browser checks for
   actual htmx morphing. Expected nodes are independent data, never view
   invocations or rerendered expected HTML; escaping mutations must fail.
8. Caramel's Ameba runner recognizes `p` and nested braces only inside
   expectation blocks, keeping debug lint elsewhere. The line limit is
   unchanged.
9. The website's HTML testing guide states the complete matching contract.

## Reasons

- Decoded elements make specs independent of quote style, attribute order and escaping spelling.
- Blueprint's finite vocabulary catches misspellings at compile time; runtime failures name the expectation path and observed content.
- Requirements read like the project's views, with one familiar vocabulary.
- Rejected: rendering a second Blueprint tree, because shared escaping defects would pass.
- Rejected: raw text helpers, because they cannot establish ancestry.
- Rejected: a homegrown HTML parser, because it repeats mature HTML5 parsing machinery.
- Rejected: browser-only assertions, because they add process overhead to request specs; browser tests stay for interactions.
- Rejected: CSS as a second complete public DSL; it serves only `within:`.
- Precedent: Rails scopes nested requirements to a matched ancestor and separates partial requirements from equality. Laravel shows that text presence alone does not prove structure. Phlex shows that a view DSL need not be the assertion engine and that a real parser should be used. These are design precedents, not execution models: Corretto drives in-process requests against real database branches.
