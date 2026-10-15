Reference / Views

# HTML, written in Crystal.

A view is a Crystal class whose methods write HTML, and everything it writes is escaped unless you mark it as trusted.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | A Caramel application with views under `app/views/` |
| You will have | Typed HTML views that escape everything they write |
| Proved by | Corretto HTML expectations |

Learning it for the first time? The recipe [Create a resource](https://caramelize.dev/cookbook/0.16.0/create-a-resource/index.md) generates a show view and a form view you can read. This page lists every element, attribute and rule.

## Limits at a glance {#c-views-limits}

| Limit | Value |
| --- | --- |
| Island name | 1–64 characters |

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
| An `initialize` argument of the wrong type, or markup outside `private def blueprint` that is not Crystal | fails compilation |
| A second `to_s` on one view object | raises `Can only invoke 'to_s' once on String::Builder`; build a new view for each response |

| File | Role |
| --- | --- |
| `app/views/application_view.cr` | The base class every view subclasses. |
| `app/views/layouts/application.cr` | The layout around every page. |
| `app/views/home/index.cr` | The generated home page. |

## Element blocks write escaped text {#c-views-elements}

Each HTML element is a method. For example, `h1 { "<Dune>" }` writes `<h1>&lt;Dune&gt;</h1>`.

| Condition | Outcome |
| --- | --- |
| The value an element’s block returns, when the block wrote nothing | is escaped text |
| The value an element’s block returns, once the block wrote an element | is dropped: `p { "a"; strong { "b" } }` writes only `<p><strong>b</strong></p>` |
| `plain` inside a block that writes elements | writes escaped text beside them |

**app/views/books/show.cr · inside blueprint, text beside an element**

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
| An attribute value | is escaped like text: `&`, `<`, `>`, `"` and `'` become entities |
| htmx 4 attributes that children inherit | carry an `:inherited` suffix; a symbol cannot spell the colon, so quote the name |
| An attribute name that contains `<`, `>`, `&` or a quote | raises ArgumentError |

**Inside blueprint · a quoted name and boolean attributes**

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
| An island name that is not an upper-case ASCII letter followed by 0 to 63 ASCII letters or digits (`/\A[A-Z][A-Za-z0-9]{0,63}\z/`) | raises ArgumentError |
| `CaramelIslands.define("Rating", (element, props) => { … })` in `app/assets/javascript/app.js` | brings it to life |
| `raw value` with a `Caramel::HTML::Safe` or `safe(...)` value | writes it unescaped |
| `raw value` with anything else | fails compilation, so an ordinary string cannot reach the page raw by accident |

[Mount a third-party component →](https://caramelize.dev/cookbook/0.16.0/third-party-components/index.md)

Only HTML your application built itself belongs in `Safe`. Never wrap user input, stored text or a third-party response.

## markup builds small escaped fragments {#c-views-markup}

`markup { … }` builds a fragment in an action or a view without a view class.

**Inside an action · one element for morph**

```crystal
morph "#count", with: markup { span { count.to_s } }
```

| Condition | Outcome |
| --- | --- |
| `markup { … }` in an action or a view | escapes like a view and returns a `Caramel::HTML::Safe` |
| Element methods such as `span`, `label` or `title` inside the block | come first; surrounding methods and local variables stay available |

## Forms carry the CSRF token {#c-views-forms}

A form that posts carries the CSRF token in a hidden `_csrf` field, and a form for PATCH or DELETE names its method in `_method`. htmx requests need no hidden field: the layout’s `hx-headers` sends the token as `X-CSRF-Token`.

| Condition | Outcome |
| --- | --- |
| A form that posts with the hidden `_csrf` field, or an htmx request with the layout’s header | passes the check that [Security defaults](https://caramelize.dev/docs/0.16.0/security/index.md) states |
| A form that posts without the field, from a page without the header | answers 403 |
| `_method` of `PATCH`, `PUT` or `DELETE` in a posted form | routes as that method; [Routes and contracts](https://caramelize.dev/docs/0.16.0/routes-and-contracts/index.md) lists the cases |

**app/views/books/show.cr · inside blueprint, a delete button**

```crystal
form action: book_path(@book.id), method: "post" do
  input type: "hidden", name: "_csrf", value: @csrf_token
  input type: "hidden", name: "_method", value: "DELETE"
  button(type: "submit") { "Delete" }
end
```

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

Test what a view writes through a real response. Corretto’s HTML expectations describe elements and decoded text, recorded apart from Blueprint’s renderer. The command assumes the Book resource of [Your first application](https://caramelize.dev/docs/0.16.0/getting-started/index.md), step 02; generate it first.

**Terminal · inside the application**

```bash
frappe corretto spec/requests/books_spec.cr
```

**Passing:** The generated spec is green and the run ends with `Corretto: 1 of 1 workers passed`. A shared escaping defect cannot make both sides agree, because the expectations are recorded apart from Blueprint’s renderer.

[Test the HTML →](https://caramelize.dev/docs/0.16.0/testing-html/index.md)

[← Actions and responses](https://caramelize.dev/docs/0.16.0/actions-and-responses/index.md) · [Store the data →](https://caramelize.dev/docs/0.16.0/sugarorm/index.md)

Caramel 0.16.0 · https://caramelize.dev/docs/0.16.0/views/
