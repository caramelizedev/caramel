Cookbook / Data and forms

# Submit the form your view renders.

Post exactly the fields a page renders, so a request spec fails when a view and its action’s contract disagree.

Proved by scripts/check page-forms · Target: 0.20.0

| Contract | Value |
| --- | --- |
| Needs | The machine setup of [Your first application](https://caramelize.dev/docs/0.20.0/getting-started/index.md); the recipe generates its own Book resource |
| You will have | A `submit_rendered_form` spec helper that reads a page’s form with Corretto’s HTML parser and posts every field it renders, and a request spec that submits the new book form |
| Status | Run end to end by `scripts/check page-forms` |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Where the change goes {#c-forms-files}

- `spec/support/rendered_form.cr`: Reads and submits forms
- `spec/requests/book_form_spec.cr`: Submits the new form

## Create the application and its Book {#c-forms-create}

The application is `bookshelf`. Its Book has two text fields and a `Bool`, which the generated form renders as a select.

1. **Generate and migrate**

   **Terminal · after machine setup**

   ```bash
   frappe new bookshelf
   cd bookshelf
   frappe make resource Book title:string author:string in_print:bool
   frappe migrate
   ```

   **Expect:** `frappe new` prints `Created bookshelf.`, then `bookshelf is configured at https://bookshelf.caramel`. `make resource` prints `Generated PATH` for each file it writes. `frappe migrate` prints `Applied 1 migrations.`, then `The database matches the declared schema.`

## A hand-built spec never sends what only the view renders {#c-forms-gap}

The generated `spec/requests/books_spec.cr` posts a params hash it writes itself. A browser posts the fields the form renders. An action’s contract refuses a field it does not declare, so a field only the view has fails in the browser and passes in that spec. [Read the contract rules →](https://caramelize.dev/docs/0.20.0/routes-and-contracts/index.md)

| Condition | Outcome |
| --- | --- |
| A spec posts a params hash it builds itself | sends only the fields the spec names |
| A spec posts the form the page rendered | sends every field the view renders, as a browser does |
| `fill` names a field the form does not render | raises ArgumentError |

## Read the form the page rendered {#c-forms-helper}

Corretto parses HTML with Lexbor. The helper reads the page’s first form, takes the value each named field renders, replaces the values `fill` names and submits the form to its `action` with its `method`.

1. **Write the helper**

   **spec/support/rendered_form.cr**

   ```crystal
   # Submits the first form on *page* as a browser would: every named input,
   # select and textarea it renders, with *fill* replacing the values it names.
   def submit_rendered_form(client : Corretto::Client, page : Caramel::Response,
                            fill : Hash(String, String)) : Caramel::Response
     action, verb, values = read_form(page.body)
     fill.each do |name, value|
       raise ArgumentError.new("The form has no field #{name}") unless values.has_key?(name)
       values[name] = value
     end
     verb == "post" ? client.post(action, params: values) : client.get(action, params: values)
   end

   # The form's action, its method and the value of each field it renders.
   private def read_form(html : String) : {String, String, Hash(String, String)}
     Corretto::HTML::Document.open(html) do |document|
       form = document.select("form").first? || raise ArgumentError.new("The page has no form")
       action = form["action"]? || raise ArgumentError.new("The form has no action")
       values = {} of String => String
       read_inputs(form, values)
       read_selects(form, values)
       form.css("textarea[name]") { |area| values[area["name"]] = area.inner_text }
       {action, form["method"]?.try(&.downcase) || "get", values}
     end
   end

   # Each input that a browser submits: not a button, and not an unchecked box.
   private def read_inputs(form : Lexbor::Node, values : Hash(String, String)) : Nil
     form.css("input[name]") do |input|
       type = input["type"]?.try(&.downcase) || "text"
       next if type.in?("submit", "button", "reset", "image")
       next if type.in?("checkbox", "radio") && !input.has_key?("checked")
       values[input["name"]] = input["value"]? || ""
     end
   end

   # Each select's selected option, or its first.
   private def read_selects(form : Lexbor::Node, values : Hash(String, String)) : Nil
     form.css("select[name]") do |field|
       options = [] of {String, Bool}
       field.css("option") do |option|
         options << {option["value"]? || option.inner_text, option.has_key?("selected")}
       end
       chosen = options.find(&.[1]) || options.first?
       values[field["name"]] = chosen.try(&.[0]) || ""
     end
   end
   ```

   **Expect:** The helper skips submit buttons and unchecked boxes, takes a select’s selected option or else its first, and raises `ArgumentError` when the page has no form or `fill` names a field the form does not render. `frappe corretto` runs only `*_spec.cr` files, so the helper runs where a spec requires it.

## Submit the new book form {#c-forms-spec}

The spec loads `/books/new`, fills the two text fields and submits what the page rendered. `in_print` keeps the value the form renders, `true`, the select’s first option.

1. **Write the spec**

   **spec/requests/book_form_spec.cr**

   ```crystal
   require "../spec_helper"
   require "../support/rendered_form"

   describe "The new book form" do
     it "creates a book when submitted as the page renders it" do
       Corretto.session do |client, db|
         page = client.get("/books/new")
         page.should render_page("New book")
         fill = {"title" => "Dune", "author" => "Frank Herbert"}
         created = submit_rendered_form(client, page, fill)
         created.should have_status(303)
         db.should have_row(App::Book, title: "Dune", author: "Frank Herbert", in_print: true)
       end
     end
   end
   ```

   **Expect:** The book is created and the response redirects with 303, as for a browser.
2. **Run it**

   **Terminal · inside the application**

   ```bash
   frappe corretto spec/requests/book_form_spec.cr
   ```

   **Expect:** Ends with `Corretto: 1 of 1 workers passed`, after a worker line reading `1 examples, 0 failures, 0 errors, 0 pending`.

Prove it

## Prove the form spec {#c-forms-prove}

**Terminal · inside the application**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` and `frappe lint` exit 0. `frappe corretto` runs the form spec beside the generated book spec and ends with `Corretto: 1 of 1 workers passed`.

> Proved **Run end to end by a check.**
>
> `scripts/check page-forms` creates `bookshelf`, generates and migrates the Book resource, copies the helper and the spec at the steps above, and runs `frappe check`, `frappe corretto` and `frappe lint`. It then adds `input type: "hidden", name: "operation_key", value: "draft"` to `app/views/books/form.cr`. `spec/requests/books_spec.cr` still passes and `book_form_spec.cr` fails with `Expected status 303, got 422`. Finally it restores the view.

[← All recipes](https://caramelize.dev/cookbook/0.20.0/) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.20.0/testing-html/index.md)

Caramel 0.20.0 · https://caramelize.dev/cookbook/0.20.0/rendered-forms/
