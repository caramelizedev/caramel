Cookbook / Requests and responses

# Read and write JSON.

Answer a generated Book resource’s actions as JSON, bind a JSON object to their contracts, and let an update check the version it was sent with If-Match.

Proved by scripts/check page-json · Target: 0.17.0

| Contract | Value |
| --- | --- |
| Needs | A generated Book resource, as in [Create a resource](https://caramelize.dev/cookbook/0.17.0/create-a-resource/index.md) |
| You will have | JSON answers from the generated actions, a version each book carries as `ETag`, updates that check `If-Match`, and a request spec for 200, 201, 412, 403, 400, 415 and 422 |
| Status | Run end to end by `scripts/check page-json` |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Where the change goes {#c-json-files}

- `app/models/book.cr`: The version field, kept out of the JSON
- `db/migrations/`: The version column
- `app/actions/books/show.cr`: Sends the version
- `app/actions/books/update.cr`: Checks If-Match
- `spec/requests/books_json_spec.cr`: JSON request examples

## Ask for a JSON response {#c-json-response}

A generated action returns its result from `handle` and renders HTML in `render`. A client that sends `Accept: application/json` gets the result as JSON instead: the index answers `records`, the show `record`, and the create `record` with status 201. A failed contract or changeset answers 422 with an `errors` object, and the generated request spec already reads one book this way.

[Read how actions answer JSON →](https://caramelize.dev/docs/0.17.0/actions-and-responses/index.md)

## Give each book a version {#c-json-version}

A JSON client edits a book it read earlier. A version field lets the update refuse a change made from a stale copy: the show action sends the version as `ETag`, and the update checks the `If-Match` header against it before writing.

1. **Add the version field**

   **app/models/book.cr**

   ```crystal
   module App
     struct Book < SugarORM::Schema
       schema "books" do
         field id : Int64, primary: true
         field title : String
         field author : String
         field lock_version : Int32, version: true
         timestamps
         json :id, :title, :author, :created_at, :updated_at
       end
     end
   end
   ```

   `version: true` starts the column at 0 and adds one on every update. The `json` line stays as generated, so `lock_version` is never in the JSON: the `ETag` carries it. [Read the version rules →](https://caramelize.dev/docs/0.17.0/sugarorm/index.md)

   **Terminal · inside the application**

   ```bash
   frappe db diff --name add_book_lock_version
   ```

   **Expect:** Prints `Wrote` and the path of one migration ending in `_add_book_lock_version.cr`, which adds `"lock_version" integer NOT NULL DEFAULT 0` to `books`.
2. **Apply the migration**

   **Terminal · inside the application**

   ```bash
   frappe migrate
   ```

   **Expect:** Prints `Applied 1 migrations.`, then `The database matches the declared schema.`
3. **Send the version, then check it**

   Replace the generated show and update actions. `self.etag = version` adds `ETag: "0"` to a successful JSON answer, and `if_match?(version)` is true with no `If-Match` header or one that names that version. [Read the ETag and If-Match rules →](https://caramelize.dev/docs/0.17.0/actions-and-responses/index.md)

   **app/actions/books/show.cr**

   ```crystal
   module App::Books
     struct Show < App::ApplicationAction
       contract do
         field id : Int64, min: 1
       end

       def handle(contract : Contract)
         record = App::Book.query.find(contract.id)
         return not_found("Book not found") unless record
         self.etag = record.lock_version
         {record: record}
       end

       def render(result)
         page "Book", Views::Books::Show.new(result[:record], csrf_token)
       end
     end
   end
   ```

   **app/actions/books/update.cr**

   ```crystal
   module App::Books
     struct Update < App::ApplicationAction
       include Form

       contract do
         field id : Int64, min: 1
         field title : String
         field author : String
       end

       def handle(contract : Contract)
         record = App::Book.query.find(contract.id)
         return not_found("Book not found") unless record
         unless if_match?(record.lock_version)
           return render_errors({"_base" => [SugarORM::Wording.record_stale]}, 412)
         end
         changes = record.update(title: contract.title, author: contract.author)
         return render_form(contract.values, changes.errors, contract.id, 422) unless changes.saved?
         self.etag = changes.record.lock_version
         {record: changes.record}
       end

       def render(result)
         redirect_to(book_path(result[:record].id))
       end
     end
   end
   ```

   The browser form still works: it sends no `If-Match`, so the update writes, and the generated request spec keeps passing.

## Bind a JSON object to the contract {#c-json-input}

With `Content-Type: application/json`, a top-level object binds to the contract by member name, and numbers bind as their source text. `_csrf` and `_method` are ordinary members: a JSON client sends `X-CSRF-Token` and the real method. Corretto’s `json:` sends the object and the header; it adds the origin, cookie and CSRF token as a browser would, and a header you pass replaces the one it adds.

[Read how each value binds →](https://caramelize.dev/docs/0.17.0/routes-and-contracts/index.md)[Read the CSRF rules →](https://caramelize.dev/docs/0.17.0/security/index.md)

| Condition | Outcome |
| --- | --- |
| Malformed JSON | answers 400 |
| A JSON value that is not an object | answers 422 with `Expected a JSON object` under `_base` |
| A missing or invalid field | answers 422 with the error under the field |
| A media type other than a form or `application/json` | answers 415 |
| A forged `X-CSRF-Token` | answers 403 |
| `If-Match` names another version | answers 412 from the update above |

An update whose row changed between its read and its write, with no `If-Match` to catch it, fails the changeset instead: `stale?` is true and the generated action answers 422. [Read what a stale changeset does →](https://caramelize.dev/docs/0.17.0/sugarorm/index.md)

> **External callers need their own credential**
>
> An API that skips browser CSRF must declare an authenticator with ingress. Its session is empty and unsaved; authenticate with a bearer token or signature that a browser does not attach automatically. [Receive a signed webhook →](https://caramelize.dev/cookbook/0.17.0/webhooks/index.md)

Prove it

## Prove the JSON behavior {#c-json-prove}

Add the request spec beside the generated one, then run the checks.

**spec/requests/books_json_spec.cr**

```crystal
require "../spec_helper"

describe "Books as JSON" do
  it "lists and shows books, with the version as an ETag" do
    Corretto.session do |client, db|
      App::Book.create(title: "Dune", author: "Frank Herbert")
      accept = {"Accept" => "application/json"}
      listed = client.get("/books", headers: accept)
      listed.should have_status(200)
      records = JSON.parse(listed.body)["records"].as_a
      records.map(&.["title"].as_s).should eq(["Dune"])
      book = App::Book.query.first!(db)
      shown = client.get("/books/#{book.id}", headers: accept)
      shown.should have_status(200)
      shown.should have_header("ETag", %("0"))
      JSON.parse(shown.body)["record"].as_h.has_key?("lock_version").should be_false
    end
  end

  it "creates a book from JSON and updates it when If-Match holds" do
    Corretto.session do |client, _db|
      accept = {"Accept" => "application/json"}
      book = {title: "Dune", author: "Frank Herbert"}
      created = client.post("/books", json: book, headers: accept)
      created.should have_status(201)
      path = "/books/#{JSON.parse(created.body)["record"]["id"].as_i64}"
      edited = {title: "Dune Messiah", author: "Frank Herbert"}
      stale = accept.merge({"If-Match" => %("7")})
      refused = client.patch(path, json: edited, headers: stale)
      refused.should have_status(412)
      refused.body.should eq(%({"errors":{"_base":["Record changed since you loaded it"]}}))
      current = accept.merge({"If-Match" => %("0")})
      updated = client.patch(path, json: edited, headers: current)
      updated.should have_status(200)
      updated.should have_header("ETag", %("1"))
      JSON.parse(updated.body)["record"]["title"].as_s.should eq("Dune Messiah")
    end
  end

  it "answers 403, 400, 415 and 422 to writes it cannot take" do
    Corretto.session do |client, _db|
      accept = {"Accept" => "application/json"}
      book = {title: "Dune", author: "Frank Herbert"}
      forged = accept.merge({"X-CSRF-Token" => "forged"})
      client.post("/books", json: book, headers: forged).should have_status(403)
      json = accept.merge({"Content-Type" => "application/json"})
      client.post("/books", body: "{", headers: json).should have_status(400)
      text = accept.merge({"Content-Type" => "text/plain"})
      client.post("/books", body: "Dune", headers: text).should have_status(415)
      missing = client.post("/books", json: {title: "Dune"}, headers: accept)
      missing.should have_status(422)
      missing.body.should eq(%({"errors":{"author":["is required"]}}))
      array = client.post("/books", json: ["Dune"], headers: accept)
      array.should have_status(422)
      JSON.parse(array.body)["errors"]["_base"].as_a.should eq(["Expected a JSON object"])
    end
  end
end
```

**Terminal · inside the application**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` and `frappe lint` exit 0, and `frappe corretto` ends with `Corretto: 1 of 1 workers passed` after the three JSON examples and the generated ones pass.

> Proved **Run end to end by a check.**
>
> `scripts/check page-json` creates an application, generates the Book resource, applies the migration, copies these files at the steps above and runs the proof, and the website build holds every snippet on this page to those files.

[← All recipes](https://caramelize.dev/cookbook/0.17.0/) · [Receive a signed body →](https://caramelize.dev/cookbook/0.17.0/webhooks/index.md)

Caramel 0.17.0 · https://caramelize.dev/cookbook/0.17.0/return-json/
