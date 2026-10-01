# Testing HTML with Corretto

Corretto drives real requests and inspects their responses. Require
`"caramel/corretto"` from your spec helper; its matchers work with Crystal's
`should` and `should_not`.

```crystal
shown.should have_html {
  section(class: "form-page") {
    h1 { "Book" }
    dl { dd { "<Dune>" } }
    a(href: "#{path}/edit") { "Edit book" }
  }
}

created.should render_partial("#note-list", swap: "beforeend") {
  li { "<b>Milk</b> ×2" }
}
```

The block describes requirements for the HTML actually returned. It uses
Blueprint's standard element names, including `select_tag` for `select`, but
records values independently of Blueprint's renderer. Do not instantiate an
application view to construct expected output. Use `element("book-card", …)`
for a custom tag; a typo such as `h11` is a compile error. Captured locals and
loops work as ordinary Crystal code.

## Selected requirements

Each expectation block must declare exactly one root element. By default:

- Additional attributes and markup are allowed. A nested requirement may be
  below extra wrappers, and sibling order does not matter.
- All nested requirements must belong to the same matched ancestor. Sibling
  requirements consume distinct nodes; one `li` cannot satisfy two `li` calls.
- A string returned from an element block requires its exact decoded descendant
  text. HTML whitespace (space, tab, line feed, form feed and carriage return)
  collapses to a single space, with surrounding spaces removed. Nonbreaking
  spaces stay distinct. Text inside `pre` and `textarea` keeps its whitespace.
- Numbers, booleans and characters returned from a leaf element block check
  their literal `to_s` text too: `small { copies }` checks the quantity. Numeric
  loop return values are ignored when the block has recorded child requirements.
  Convert other leaf values explicitly, such as `time { published_at.to_s }`;
  unsupported values raise instead of silently skipping the text check. Empty
  collection loops and `nil` results add no text requirement.
- Expected strings are literal text, never HTML. `"<b>Milk</b>"` matches escaped
  text and fails against an actual `b` element containing `Milk`.
- Attributes compare decoded values. Class names are a token subset;
  `disabled: true` requires presence and `disabled: false` requires absence.
  Extra attributes are allowed. Arrays flatten, omit `nil` and join with spaces;
  nested keyword values produce names such as
  `data: {book_id: 7}` → `data-book-id="7"`.
- Boolean values always assert presence or absence, matching Blueprint's
  attribute syntax. Use strings for ARIA/data values: `aria_expanded: "false"`
  requires that literal value, whereas `aria_expanded: false` requires absence.
- `plain` checks direct text alongside nested elements. Comments do not split
  adjacent text; an actual intervening element does:

  ```crystal
  rejected.should have_html {
    li {
      code { "seats" }
      plain ": must be at least 1"
    }
  }
  ```

Distinctness applies at each requirement level. Because selected requirements
allow extra wrappers, distinct matched ancestors can share a deeper descendant.
Use record identity attributes when describing repeated records, as in
`li(data: {order_id: id})`, or use `strict: true` for direct sibling structure.

Without `count:`, at least one root must match. With it, exactly that many roots
must match the complete pattern. `within:` selects the containing scope with a
CSS selector; matching roots must be descendants of that scope.

```crystal
shown.should have_html(within: "#books", count: 2) { li(class: "book") }
shown.should have_html(count: 0) { script(src: "/unexpected.js") }
shown.should_not have_html { p { "Access denied" } }
```

Negation inverts the complete expectation, including its count. An invalid CSS
selector, missing scope, negative count, empty or multiple-root block, or parser
failure raises an error even in a negative assertion. HTML5 parsing repairs
malformed HTML as a browser does; this is not an HTML conformance validator.

## Strict structure and response matchers

`strict: true` compares all attributes and the direct child structure, order,
and text. Comments and insignificant formatting whitespace are ignored; classes
remain an unordered token set. Use it when the complete subtree is the contract.
For mixed content, describe direct text with `plain` between element calls.

```crystal
shown.should have_html(strict: true) {
  ul(class: "books") {
    li { "Dune" }
    li { "Solaris" }
  }
}
```

The existing `render_partial(target, swap:)` signature still works. Its new block
checks content within the *same* `hx-partial` that supplies the target and swap.
`render_page("Books")` requires a source doctype and a parsed title containing
`Books`; a title-bearing fragment does not count as a full page. Attribute order,
quote style and entity spelling do not affect these assertions.

Full documents and fragments are supported. Standalone table cells, rows, table
sections and options are parsed in the appropriate HTML5 fragment context.
`hx-partial` envelopes use htmx's template parsing treatment, so raw table rows
and cells inside them survive. Ordinary templates remain inert. The adapter
restores envelope nodes for scoping and diagnostics after parsing.
Assertions parse once, release their native document afterwards and retain
bounded diagnostics with the expectation path, count and relevant HTML.

Keep exact-output assertions for serialization, escaping bytes and wire
protocols. Keep browser checks for htmx's actual DOM morphing. Server-side DOM
assertions cannot prove JavaScript behavior.

## Installation and lint

Caramel pins the Lexbor Crystal shard to 3.6.4 as a development dependency.
Generated applications declare it explicitly under `development_dependencies`,
and their lockfiles retain that pin for frozen development installs. Production
installs (`shards install --production`) neither restore nor build the parser.
Its development postinstall downloads a SHA-256-verified Lexbor 3.0.0 C source
and builds a static library with `cc` and `ar`. macOS needs Apple's Command Line
Tools; Linux needs a C toolchain (`build-essential` on Debian/Ubuntu). A clean
install needs network access for that source download. Use
`scripts/shards install --frozen` in the managed macOS checkout, or `frappe setup`
in an application. The Linux session hook installs the native build prerequisites
and restores dependencies with its pinned Crystal compiler and Shards.

Existing applications must add the parser before using these matchers, then
refresh `shard.lock` with `shards install` in their managed compiler environment
and run `frappe setup`. Setup uses a frozen install and does not create missing
lock entries:

```yaml
development_dependencies:
  lexbor:
    github: kostya/lexbor
    version: 3.6.4
```

Only Corretto requires the parser; ordinary application builds do not link it.
Access to partials' native template content follows Lexbor's pinned layout;
upgrading the parser requires reviewing that binding and its context specs.
The managed Crystal wrapper also handles bare `.cr` invocations in dependency
hooks so they receive the managed OpenSSL paths.

`frappe lint` recognizes paragraph calls and nested curly blocks inside
`have_html` and `render_partial`. Debug calls elsewhere, and `pp`/`p!` inside
expectations, remain linted. This scoped rule is in Caramel's linter; upstream
Ameba editor integrations alone do not load it. The 100-character line limit
still applies.

The design and comparisons with Rails, Laravel, Phoenix, Phlex and Lucky are
recorded in [ADR 0022](decisions/0022-html-expectations.md).

The [production case inventory and authoring evaluation](research/corretto-html-testing.md)
records realistic edge cases, the functional request workflows, and the
ergonomics findings that drive regression coverage.
