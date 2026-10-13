Reference / Views

# HTML, written in Crystal.

A view is a Crystal class whose methods write HTML, and everything it writes is escaped unless you mark it as trusted.

## A view is a class {#c-views-class}

Views live under `app/views/`. Each one is a Blueprint class that subclasses `App::ApplicationView`. That base is a `Caramel::View` with the application’s path helpers.

The view’s inputs are typed in `initialize`. Its markup goes in `private def blueprint`. The compiler checks both.

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

An action renders it as the page: `page "Book", Views::Books::Show.new(book, csrf_token)`. A view renders once. Build a new one for each response.

- `app/views/application_view.cr`: The base class every view subclasses.
- `app/views/layouts/application.cr`: The layout around every page.
- `app/views/home/index.cr`: The generated home page.

## Elements and text {#c-views-elements}

Each HTML element is a method. The value its block returns is escaped text, so `h1 { "<Dune>" }` writes `<h1>&lt;Dune&gt;</h1>`.

Inside a block that writes elements, `plain` writes escaped text beside them.

**A paragraph with text and an element**

```crystal
p do
  plain "by "
  strong { @book.author || "Unknown" }
end
```

- `whitespace` writes one space, for instance between two links.
- `comment "text"` writes an HTML comment.
- `doctype` writes `<!DOCTYPE html>`.
- `element("book-card") { … }` writes a custom tag.

## Attributes {#c-views-attributes}

Attributes are keyword arguments. Their values are escaped like text, so `&`, `<`, `>` and both quotes are safe.

- `hx_get: "/books"`: hx-get="/books": underscores become dashes.
- `"hx-swap:inherited": "innerMorph"`: The name exactly as quoted, for names a symbol cannot spell.
- `checked: true`: checked. false and nil leave the attribute out.
- `class: ["card", (tagged ? "tagged" : nil)]`: class="card tagged", dropping nil.
- `data: {book_id: book.id}`: data-book-id="1".

htmx 4 attributes that children inherit carry an `:inherited` suffix. A symbol cannot spell the colon, so quote the name. An attribute name that contains `<`, `>`, `&` or a quote raises an error.

**Quoted and boolean attributes**

```crystal
div "hx-swap:inherited": "innerMorph" do
  input type: "checkbox", name: "done", checked: true, disabled: false
end
```

## Child views, islands and trusted HTML {#c-views-composing}

- `render Card.new(book)` writes a child view in place: `@books.each { |book| render Card.new(book) }`.
- `island "Rating", {stars: 4}` writes a `<caramel-island>` mount point with the props as JSON. The name must be PascalCase. In `app/assets/javascript/app.js`, `CaramelIslands.define("Rating", (element, props) => { … })` brings it to life. [Mount a third-party component →](https://caramelize.dev/cookbook/0.14.0/third-party-components/index.md)
- `raw value` writes a `Caramel::HTML::Safe` or a `safe(...)` value unescaped. It accepts nothing else, so an ordinary string cannot reach the page raw by accident.

Only HTML your application built itself belongs in `Safe`. Never wrap user input, stored text or a third-party response. Escaped text is the default for a reason.

## Small fragments with markup {#c-views-markup}

An action or a view can build a fragment too small for a class with `markup { … }`. It escapes like a view and returns a `Caramel::HTML::Safe`.

**An action morphs one element**

```crystal
morph "#count", with: markup { span { count.to_s } }
```

Inside the block, element methods such as `span`, `label` or `title` come first. The surrounding methods and local variables stay available.

## Forms {#c-views-forms}

A form that posts carries the CSRF token in a hidden `_csrf` field. A form for PATCH or DELETE posts and names its method in `_method`.

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

## The application layout {#c-views-layout}

The layout receives the rendered `Caramel::Page` and the CSRF token. It writes the page’s HTML with `raw @page.html`.

- `html lang: Caramel.language` names the request’s language: `en` unless the app uses `caramel/i18n`.
- The head loads `app.css`, htmx, `caramel-islands.js` and `app.js`, the scripts deferred.
- The body sets inherited htmx attributes: boosted links, `#content` as the target, `innerMorph` swaps and the CSRF header.

**app/views/layouts/application.cr · the body**

```crystal
body "hx-boost:inherited": "true", "hx-target:inherited": "#content", "hx-swap:inherited": "innerMorph",
  "hx-headers:inherited": {"X-CSRF-Token" => @csrf_token}.to_json do
  main(id: "content") { raw @page.html }
end
```

## Testing views {#c-views-testing}

Test what a view writes through a real response. Corretto’s HTML expectations describe elements and decoded text, recorded apart from Blueprint’s renderer. A shared escaping defect cannot make both sides agree.

[Test the HTML →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Store the data →](https://caramelize.dev/docs/0.14.0/sugarorm/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/views/
