# Views

A view is a Blueprint class under `app/views/`. Its inputs are typed in `initialize`, and its markup is Crystal in `private def blueprint` ([ADR 0018](decisions/0018-blueprint-views.md)). Everything below is escaped unless it is a `Caramel::HTML::Safe`.

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

## Elements and text

Each HTML element is a method. Its block's return value is escaped text, so `h1 { "<Dune>" }` writes `<h1>&lt;Dune&gt;</h1>`. Inside a block that writes elements, `plain` writes escaped text beside them:

```crystal
p do
  plain "by "
  strong { @book.author || "Unknown" }
end
```

`whitespace` writes a single space, for instance between two links. `comment "text"` writes an HTML comment, and `doctype` writes `<!DOCTYPE html>`.

## Attributes

Attributes are keyword arguments. Their values are escaped.

| You write | Blueprint writes |
| --- | --- |
| `hx_get: "/books"` | `hx-get="/books"`: underscores become dashes |
| `"hx-swap:inherited": "innerMorph"` | the name exactly as quoted, for names a symbol cannot spell |
| `checked: true` | `checked`; `false` and `nil` leave the attribute out |
| `class: ["card", (tagged ? "tagged" : nil)]` | `class="card tagged"`, dropping `nil` |
| `data: {book_id: book.id}` | `data-book-id="1"` |

## Other views, islands and trusted HTML

- `render Views::Books::Card.new(book)` writes a child view in place, as in `@books.each { |book| render Card.new(book) }`.
- `island "Rating", {stars: 4}` writes a client island ([ADR 0005](decisions/0005-island-props-helper.md)), which `CaramelIslands.define("Rating", …)` in `app/assets/javascript/app.js` brings to life.
- `raw value` writes a `Caramel::HTML::Safe` unescaped. It accepts nothing else, so an ordinary string cannot reach the page raw by accident. Only HTML your application built itself belongs in `Safe`.

A layout receives the rendered page and writes its body with `raw @page.html`.

## Small fragments without a class

An action can build a fragment too small for a view class with `markup`, which escapes like a view:

```crystal
morph "#count", with: markup { span { count.to_s } }
```

Inside the block, element methods such as `span` or `title` come first; the action's other methods and local variables stay available.

## Forms

A form that posts needs the CSRF token, and a form for PATCH or DELETE also names its method:

```crystal
form action: book_path(@book.id), method: "post" do
  input type: "hidden", name: "_csrf", value: @csrf_token
  input type: "hidden", name: "_method", value: "DELETE"
  button(type: "submit") { "Delete" }
end
```

`frappe make resource` generates a complete form view to start from, with labels, error summaries and `aria` attributes. htmx requests from the generated layout already send the token in `X-CSRF-Token`.

## Testing rendered views

Use Corretto’s [HTML expectations](testing.md) to describe elements and decoded
text in the response. Expected values are recorded independently of Blueprint’s
renderer, so a shared escaping defect cannot make both sides agree. Keep byte
assertions when serialization itself is the behavior under test.
