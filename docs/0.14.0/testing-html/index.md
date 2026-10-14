Guides / Corretto

# Test the HTML your app returns.

Describe rendered elements with Blueprint-shaped expectations while Corretto drives real requests and isolated database state.

| Contract | Value |
| --- | --- |
| Needs | A generated application with Lexbor 3.6.4 as a development dependency |
| You will have | Request specs that assert rendered elements against isolated database state |
| Covers | `have_html`, `render_page`, `render_partial`, `strict: true` and scoped matching |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Start with a real response {#c-test-start}

Generated spec helpers require `caramel/corretto` and call `Corretto.configure(App)`. Inside an example, use a session to request the page and assert its observable output.

**spec/requests/books_spec.cr · after creating a Book titled \<Dune\>**

```crystal
shown = client.get(path)
shown.should have_status(200)
shown.should render_page("Book")
shown.should have_html {
  section(class: "form-page") {
    h1 { "Book" }
    dl { dd { "<Dune>" } }
    a(href: "#{path}/edit") { "Edit book" }
  }
}
```

The block records requirements independently of the view renderer. Expected strings are decoded literal text: `"<Dune>"` checks escaped user text. Build expectations from values and elements, rather than rendering an application view as the expected result.

## Select the requirements that matter {#c-test-requirements}

| Rule | What matches |
| --- | --- |
| Roots | each block has one root |
| Wrappers and attributes | extra wrappers, markup and attributes are allowed by default; a nested requirement may sit below extra wrappers |
| Order | sibling order does not matter; nested requirements belong to the same matched ancestor; sibling requirements consume distinct nodes |
| Text | exact after HTML whitespace normalization: space, tab, line feed, form feed and carriage return collapse to one space, with surrounding spaces removed; nonbreaking spaces stay distinct, and `pre` and `textarea` preserve whitespace |
| Classes | match a token subset |
| Boolean attributes | check presence or absence |
| Arrays | flatten, omit `nil` and join with spaces |
| Nested keywords | become hyphenated names: `data: {book_id: 7}` checks `data-book-id="7"` |
| ARIA and data values | use strings, such as `aria_expanded: "false"` |

**Corretto · scopes and counts**

```crystal
shown.should have_html(within: "#books", count: 2) { li(class: "book") }
shown.should have_html(count: 0) { script(src: "/unexpected.js") }
shown.should_not have_html { p { "Access denied" } }
```

Numeric, Boolean, and character leaf values check their literal text. Numeric loop return values are ignored when the block has recorded child requirements. Convert other values with `.to_s`: an unsupported value raises instead of silently skipping the text check, while empty collection loops and `nil` add no text requirement. Use `plain` for direct text beside child elements; comments do not split adjacent text, but an actual intervening element does. Loops and captured local values work; use `element("book-card")` for custom tags. Blueprint’s standard element names apply, including `select_tag` for `select`.

Distinctness applies at each requirement level, so distinct matched ancestors can share a deeper descendant. Describe repeated records with identity attributes, such as `li(data: {order_id: id})`, or use `strict: true` for direct sibling structure. Without `count:`, at least one root must match; with it, exactly that many roots must match the complete pattern. `within:` takes a CSS selector, and matching roots must be descendants of that scope. Negation inverts the complete expectation, including its count.

## Check structure and partial responses {#c-test-strict}

`strict: true` compares complete attributes and ordered direct children, ignoring comments and insignificant formatting whitespace. Classes stay an unordered set. Use it when the complete subtree is the contract; for mixed content, put `plain` between element calls.

**Corretto · a complete subtree**

```crystal
shown.should have_html(strict: true) {
  ul(class: "books") {
    li { "Dune" }
    li { "Solaris" }
  }
}
```

The block overload of `render_partial` checks target, swap, and content in the same hx-partial envelope. HTML5 table and select contexts are supported, including rows or cells inside partial envelopes.

**Corretto · fragment response**

```crystal
created.should render_partial("#note-list", swap: "beforeend") {
  li { "<b>Milk</b> ×2" }
}
```

`render_page("Books")` requires an actual source doctype and a parsed title containing Books; a title-bearing fragment is not a page. Attribute order, quoting and entity spelling do not affect these assertions. Both plain response matchers and block expectations are available.

These raise even for negative assertions:

| Condition | Outcome |
| --- | --- |
| A negative `count:` | raises ArgumentError |
| `within:` matches no element | raises ArgumentError |
| A block with no root, or more than one | raises ArgumentError |
| HTML Lexbor cannot parse | raises ArgumentError |
| An invalid selector | raises |

## Install the test dependencies {#c-test-install}

Generated applications declare Lexbor 3.6.4 as a development dependency. Keep this pin and the matching lockfile entry when configuring a project; `frappe setup` uses a frozen install. Development installs download a SHA-256-verified Lexbor 3.0.0 C source, which needs network access, and build a static library with cc and ar. macOS needs Apple’s Command Line Tools; Linux needs a C toolchain, such as `build-essential` on Debian and Ubuntu. Production installs (`shards install --production`) neither restore nor build the parser.

**shard.yml · development dependencies**

```yaml
development_dependencies:
  lexbor:
    github: kostya/lexbor
    version: 3.6.4
```

Existing applications add the same dependency, refresh `shard.lock` with `shards install` in their managed compiler environment, and run `frappe setup`, which uses a frozen install and does not create missing lock entries. Only Corretto links the parser; ordinary application builds do not.

## What does not compile {#c-test-refusals}

Each mistake below stops the build.

| Condition | Outcome |
| --- | --- |
| A misspelled standard element, such as `h11` | fails compilation |
| A Lexbor version other than 3.6.4 | fails compilation |

## Not covered yet {#c-test-gaps}

- HTML5 parsing repairs malformed HTML as a browser does; it is not a conformance validator.
- Exact-byte tests for serialization and browser tests for JavaScript and htmx morphing stay separate.
- Upstream Ameba editor integrations alone do not load Caramel’s custom rules.

Prove it

## Run the expectations {#c-test-prove}

Use `frappe lint` for the scoped paragraph and nested-block rules in expectations. Debug calls elsewhere, and `pp` or `p!` inside expectations, are still linted, and the line-length limit still applies.

**Terminal**

```bash
frappe check
frappe corretto spec/requests/books_spec.cr
frappe lint
```

**Passing:** `frappe check` prints ✓ Type check passed. `frappe corretto` reports every example passing. `frappe lint` finds no debug call outside an expectation, no `pp` or `p!` inside one, and no line over the length limit.

[← Observability](https://caramelize.dev/docs/0.14.0/observability/index.md) · [Read the current release guide →](https://caramelize.dev/docs/0.14.0/releases/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/testing-html/
