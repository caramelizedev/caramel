Reference / Views

# HTML, written in Crystal.

A view is a Crystal class whose methods write HTML, and everything it writes is escaped unless you mark it as trusted.

| Contract | Value |
| --- | --- |
| Release | 0.14.0 |
| Needs | A Caramel application with views under `app/views/` |
| You will have | Typed HTML views that escape everything they write |
| Proved by | Corretto HTML expectations |

Learning it for the first time? The recipe [Create a resource](https://caramelize.dev/cookbook/0.14.0/create-a-resource/index.md) generates a show view and a form view you can read. This page lists every element, attribute and rule.

## Limits at a glance {#c-views-limits}

| Limit | Value |
| --- | --- |
| A view instance renders | 1 time |

## A view is a class {#c-views-class}

Views live under `app/views/`. Each one is a Blueprint class that subclasses `App::ApplicationView`. That base is a `Caramel::View` with the application’s path helpers.

**app/views/books/show.cr**

```crystal
module App::Views::Books
  class Show < App::ApplicationView
    def initialize(@book : App::Book, @csrf_token : String)
    end

    private def blueprint
      h1 { @book.title }
      p { "by #{@book.author}" }
    end
  end
end
```

An action renders it as the page: `page "Book", Views::Books::Show.new(book, csrf_token)`.

| Condition | Outcome |
| --- | --- |
| Inputs typed in `initialize` and markup in `private def blueprint` | are checked by the compiler |
| A view object | renders once; build a new one for each response |

| File | Role |
| --- | --- |
| `app/views/application_view.cr` | The base class every view subclasses. |
| `app/views/layouts/application.cr` | The layout around every page. |
| `app/views/home/index.cr` | The generated home page. |

## Element blocks write escaped text {#c-views-elements}

Each HTML element is a method. For example, `h1 { "<Dune>" }` writes `<h1>&lt;Dune&gt;</h1>`.

| Condition | Outcome |
| --- | --- |
| The value an element’s block returns | is escaped text |
| `plain` inside a block that writes elements | writes escaped text beside them |

**A paragraph with text and an element**

```crystal
p do
  plain "by "
  strong { @book.author || "Unknown" }
end
```

| Call | Writes |
| --- | --- |
| `whitespace` | one space, for instance between two links |
| `comment "text"` | an HTML comment |
| `doctype` | `<!DOCTYPE html>` |
| `element("book-card") { … }` | a custom tag |

## Attribute values are escaped {#c-views-attributes}

Attributes are keyword arguments.

| Attribute | Writes |
| --- | --- |
| `hx_get: "/books"` | hx-get="/books": underscores become dashes. |
| `"hx-swap:inherited": "innerMorph"` | The name exactly as quoted, for names a symbol cannot spell. |
| `checked: true` | checked. false and nil leave the attribute out. |
| `class: ["card", (tagged ? "tagged" : nil)]` | class="card tagged", dropping nil. |
| `data: {book_id: book.id}` | data-book-id="1". |

| Condition | Outcome |
| --- | --- |
| An attribute value | is escaped like text, so &, \<, \> and both quotes are safe |
| htmx 4 attributes that children inherit | carry an `:inherited` suffix; a symbol cannot spell the colon, so quote the name |
| An attribute name that contains `<`, `>`, `&` or a quote | raises ArgumentError |

**Quoted and boolean attributes**

```crystal
div "hx-swap:inherited": "innerMorph" do
  input type: "checkbox", name: "done", checked: true, disabled: false
end
```

## Only Safe values are written raw {#c-views-composing}

| Condition | Outcome |
| --- | --- |
| `render Card.new(book)` | writes a child view in place: `@books.each { \|book\| render Card.new(book) }` |
| `island "Rating", {stars: 4}` | writes a `<caramel-island>` mount point with the props as JSON |
| An island name that is not PascalCase | raises ArgumentError |
| `CaramelIslands.define("Rating", (element, props) => { … })` in `app/assets/javascript/app.js` | brings it to life |
| `raw value` with a `Caramel::HTML::Safe` or `safe(...)` value | writes it unescaped |
| `raw value` with anything else | fails compilation, so an ordinary string cannot reach the page raw by accident |

[Mount a third-party component →](https://caramelize.dev/cookbook/0.14.0/third-party-components/index.md)

Only HTML your application built itself belongs in `Safe`. Never wrap user input, stored text or a third-party response. Escaped text is the default for a reason.

## markup builds small escaped fragments {#c-views-markup}

An action or a view can build a fragment too small for a class with `markup { … }`.

**An action morphs one element**

```crystal
morph "#count", with: markup { span { count.to_s } }
```

| Condition | Outcome |
| --- | --- |
| `markup { … }` in an action or a view | escapes like a view and returns a `Caramel::HTML::Safe` |
| Element methods such as `span`, `label` or `title` inside the block | come first; surrounding methods and local variables stay available |

## Forms carry the CSRF token {#c-views-forms}

A form that posts carries the CSRF token in a hidden `_csrf` field, and a form for PATCH or DELETE names its method in `_method`.

[Review the security defaults →](https://caramelize.dev/docs/0.14.0/security/index.md)[Read how _method routes →](https://caramelize.dev/docs/0.14.0/routes-and-contracts/index.md)

**A delete button**

```crystal
form action: book_path(@book.id), method: "post" do
  input type: "hidden", name: "_csrf", value: @csrf_token
  input type: "hidden", name: "_method", value: "DELETE"
  button(type: "submit") { "Delete" }
end
```

htmx requests need no hidden field. The layout’s `hx-headers` sends the token as `X-CSRF-Token`.

`frappe make resource` generates a complete form to start from. Its `labelled` helper writes a label, the control and the field’s errors. Its error summary is an alert listing each message.

**app/views/books/form.cr · from frappe make resource**

```crystal
private def labelled(name : String, text : String, &) : Nil
  id = "book_#{name}"
  label(for: id) { text }
  yield id
  div id: "#{id}_errors" do
    (@errors[name]? || [] of String).each { |error| p(class: "field-error") { error } }
  end
end
```

## The layout wraps every page {#c-views-layout}

The layout receives the rendered `Caramel::Page` and the CSRF token.

| Layout part | What it does |
| --- | --- |
| `raw @page.html` | writes the page’s HTML |
| `html lang: Caramel.language` | names the request’s language: `en` unless the app uses `caramel/i18n` |
| head | loads `app.css`, htmx, `caramel-islands.js` and `app.js`, the scripts deferred |
| body | sets inherited htmx attributes: boosted links, `#content` as the target, `innerMorph` swaps and the CSRF header |

**app/views/layouts/application.cr · the body**

```crystal
body "hx-boost:inherited": "true", "hx-target:inherited": "#content", "hx-swap:inherited": "innerMorph",
  "hx-headers:inherited": {"X-CSRF-Token" => @csrf_token}.to_json do
  main(id: "content") { raw @page.html }
end
```

Prove it

## Test what a view writes {#c-views-testing}

Test what a view writes through a real response. Corretto’s HTML expectations describe elements and decoded text, recorded apart from Blueprint’s renderer.

**Terminal · inside the application**

```bash
frappe corretto spec/requests/books_spec.cr
```

**Passing:** Every example is green. A shared escaping defect cannot make both sides agree, because the expectations are recorded apart from Blueprint’s renderer.

[Test the HTML →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

[← Actions and responses](https://caramelize.dev/docs/0.14.0/actions-and-responses/index.md) · [Store the data →](https://caramelize.dev/docs/0.14.0/sugarorm/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/views/
