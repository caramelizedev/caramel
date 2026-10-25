Guides / Testing HTML

# Test the HTML your app returns.

Describe rendered elements with Blueprint-shaped expectations while Corretto drives real requests and isolated database state.

| Contract | Value |
| --- | --- |
| Needs | A generated application that has run `frappe migrate`; it declares the `lexbor` shard 3.6.4 as a development dependency |
| You will have | Request specs that assert rendered elements against isolated database state |
| Covers | `have_html`, `render_page`, `render_partial`, `strict: true` and scoped matching |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Start with a real response {#c-testing-start}

The generated `spec/spec_helper.cr` already configures Corretto; the reference lists what it does. This guide works on a Book resource and the request spec its generator writes.

[Read the Corretto reference →](https://caramelize.dev/docs/0.18.0/corretto/index.md)[Submit a rendered form →](https://caramelize.dev/cookbook/0.18.0/rendered-forms/index.md)

**Terminal · inside your application**

```bash
frappe make resource Book title:string
frappe migrate
```

**Expect:** `frappe make resource` prints `Generated` for the model, changeset, actions, views, `spec/requests/books_spec.cr`, a migration, `config/routes.cr` and `config/paths.cr`, then `Run frappe migrate to apply the new schema.` `frappe migrate` ends with `The database matches the declared schema.`

Inside an example, a session requests the page and the expectation describes what the response must contain. Add this example to the generated spec:

**spec/requests/books_spec.cr · a second example**

```crystal
it "shows a book with its title escaped" do
  Corretto.session do |client, db|
    created = client.post("/books", params: {"title" => "<Dune>"})
    path = "/books/#{App::Book.query.order_by(:id, :desc).first!(db).id}"
    created.should redirect_to(path)
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
  end
end
```

The block records requirements independently of the view renderer. Expected strings are decoded literal text: `"<Dune>"` checks escaped user text. Build expectations from values and elements, rather than rendering an application view as the expected result.

## Select the requirements that matter {#c-testing-requirements}

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

## Check structure and partial responses {#c-testing-strict}

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

The block overload of `render_partial` checks the fragment’s content inside the same hx-partial envelope as its target and swap. HTML5 table and select contexts are supported, including rows or cells inside partial envelopes.

**Corretto · fragment response**

```crystal
created.should render_partial("#note-list", swap: "beforeend") {
  li { "<b>Milk</b> ×2" }
}
```

Attribute order, quoting and entity spelling do not affect these assertions. Both plain response matchers and block expectations are available; the reference lists each matcher and what it requires.

These raise even for negative assertions:

| Condition | Outcome |
| --- | --- |
| A negative `count:` | raises ArgumentError |
| `within:` matches no element | raises ArgumentError |
| A block with no root, or more than one | raises ArgumentError |
| HTML Lexbor cannot parse | raises ArgumentError |
| An invalid selector | raises |

## Install the test dependencies {#c-testing-install}

Generated applications declare the `lexbor` shard 3.6.4 as a development dependency; it builds liblexbor 3.0.0 from a SHA-256-verified source download with `cc` and `ar`, which needs network access and the C toolchain your [local environment](https://caramelize.dev/docs/0.18.0/local-environment/index.md) installs. Frappé keeps what that build writes in the toolchain, so the second application on a machine copies it in about a second instead of building it again. Keep this pin and the matching lockfile entry; `frappe setup` uses a frozen install. Production installs (`shards install --production`) neither restore nor build the parser, and only Corretto links it.

**shard.yml · development dependencies**

```yaml
development_dependencies:
  lexbor:
    github: kostya/lexbor
    version: 3.6.4
```

An application made before 0.6.0 adds the same dependency, then refreshes `shard.lock` with the framework’s Shards launcher, because `frappe setup` does not create missing lock entries:

**Terminal · inside your application**

```bash
lib/caramel/scripts/shards install
frappe setup
```

**Expect:** `shard.lock` gains a `lexbor` entry at `3.6.4` and `lib/lexbor` appears. `frappe setup` ends with `NAME is configured. Run frappe dev.`

## What does not compile {#c-testing-refusals}

Each mistake below stops the build.

| Condition | Outcome |
| --- | --- |
| A misspelled standard element, such as `h11` | fails compilation |
| A Lexbor shard version other than 3.6.4 | fails compilation with `Review Corretto’s native template layouts before changing the pinned Lexbor shard` |

## Not covered yet {#c-testing-gaps}

- HTML5 parsing repairs malformed HTML as a browser does; it is not a conformance validator.
- Exact-byte tests for serialization and browser tests for JavaScript and htmx morphing stay separate.
- Upstream Ameba editor integrations alone do not load Caramel’s custom rules.

Prove it

## Run the expectations {#c-testing-prove}

`frappe lint` exempts the paragraph `p` and multi-line curly blocks inside `have_html` and `render_partial`. Debug calls elsewhere, and `pp`, `p!` or `dump` inside an expectation, are still reported.

**Terminal**

```bash
frappe check
frappe corretto spec/requests/books_spec.cr
frappe lint
```

**Passing:** `frappe check` exits 0. `frappe corretto` ends with `Corretto: 1 of 1 workers passed`. `frappe lint` exits 0: no debug call outside an expectation, and no `pp` or `p!` inside one.

[← Observability](https://caramelize.dev/docs/0.18.0/observability/index.md) · [Read the current release guide →](https://caramelize.dev/docs/0.18.0/releases/index.md)

Caramel 0.18.0 · https://caramelize.dev/docs/0.18.0/testing-html/
