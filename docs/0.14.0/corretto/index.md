Reference / Corretto

# Test against the real thing.

Corretto runs request specs in-process against a real PostgreSQL database, rolls back every example, and fakes third parties at the wire.

## Configure the suite {#c-corretto-setup}

A generated application has a spec helper that requires `caramel/corretto` and calls `Corretto.configure(App)` once. The application is built on the spec database, with the origin and secret that `frappe corretto` supplies.

**spec/spec_helper.cr**

```crystal
require "spec"
require "caramel/corretto"
require "../config/application"

Corretto.configure(App)
```

Specs run only under `frappe corretto`. Plain `crystal spec` stops with `Run these specs with frappe corretto`. Corretto also stops if the database it was given is not this worker’s own spec database, so development data is never touched.

Spec workers start from a cleared environment. Your development `.env` never reaches them. Put the test-only settings your application reads, such as a webhook secret, in the committed `.env.test`.

**.env.test**

```bash
WEBHOOK_SECRET=test-webhook-secret
```

The file must be a regular file of at most 64 KiB. It cannot set the keys Corretto and the toolchain supply, such as `APP_ORIGIN`, `APP_SECRET` and `DATABASE_URL`, or keys starting with `SPEC_`, `CARAMEL_` or `CORRETTO_`.

## Run specs in isolated databases {#c-corretto-run}

With no paths, `frappe corretto` runs every `*_spec.cr` file under `spec`. A directory contributes its spec files; paths must be inside the project. `--concurrency` takes 1 to 8 workers and defaults to 1.

**Terminal**

```bash
frappe corretto
frappe corretto spec/requests/books_spec.cr
frappe corretto spec/requests --concurrency=4
```

The command migrates the spec database once. Latte then clones one database per worker from it. Spec files are dealt round-robin to the workers, and each worker runs its own compiled spec binary with its output lines prefixed, such as `[w1]`. The worker databases are dropped afterwards.

Every example runs on one connection inside a transaction and a savepoint. Both are rolled back when the example ends, including the writes its requests and drained jobs made. If an example changes the database schema outside that transaction, Corretto warns and recreates the worker’s database from the migrated template. Tag an example `catalog` when it must run DDL: it runs unwrapped on a migration-role connection, and the database is always reset afterwards.

A rollback does not undo file writes. Point your application’s storage at `Corretto.tmpdir`, a private directory removed after each example.

## Send requests {#c-corretto-client}

`Corretto.session` yields a client and the example’s database connection. The client calls the application’s handler in-process, in the example’s fiber, so requests share the example’s transaction. It has `get`, `post`, `put`, `patch` and `delete`, and each returns a `Caramel::Response` with streamed bodies read to the end.

**Corretto · request bodies**

```crystal
client.get("/books", params: {"page" => "2"})
client.post("/books", params: {"title" => "Dune"})
cover = Corretto.upload("spec/fixtures/cover.png", "image/png")
client.post("/books/1/cover",
  params: {"caption" => "First edition"},
  files: {"cover" => cover})
client.post("/api/books", json: {title: "Dune"})
client.post("/hooks/inbox",
  body: %({"event_id":"evt_1"}),
  headers: {"Content-Type" => "application/json"})
```

A request sends one body: URL-encoded `params:`, `params:` with `files:` as multipart, `json:` with any value, or raw `body:` text or bytes typed by your `Content-Type` header. Mixing them raises `Send one body: params: (with files: for multipart), json: or body:`. On GET, `params:` becomes the query, and any other body raises. An Array value in `params:` sends one key per item. Paths must be local, such as `/books`.

## Cookies, CSRF and redirects {#c-corretto-browser}

The client behaves like a browser on your application’s origin. It sends `Host` on every request and keeps a cookie jar from `Set-Cookie`. On body methods it adds the exact `Origin` and an `X-CSRF-Token` a page would submit. Headers you pass override the automatic ones, which is how you test a forged request. The application rejects it with 403.

**Corretto · forged requests**

```crystal
sample = {"title" => "Dune"}
forged = {"X-CSRF-Token" => "forged"}
foreign = {"Origin" => "https://attacker.example"}
client.post("/books", headers: forged, params: sample).should have_status(403)
client.post("/books", headers: foreign, params: sample).should have_status(403)
```

`client.follow_redirect` sends a GET to the last response’s `HX-Location`, or to its `Location` when the status is 3xx. Otherwise it raises. `client.sign_in(user)` writes `user.id` as `user_id` into the signed session cookie, for an application whose sign-in stores `user_id`; an application with revocable sessions signs in through its login route instead.

[Revocable sessions →](https://caramelize.dev/cookbook/0.14.0/revocable-sessions/index.md)

## Assert on responses and rows {#c-corretto-matchers}

Corretto’s matchers work with `should` and `should_not`. Response matchers fail with the status, the headers and the first 800 characters of the body.

- `have_status(status)`: The response status equals status.
- `have_header(name, value = nil)`: The header is present; with a value, one of its values equals it.
- `redirect_to(path)`: A 3xx Location, or an HX-Location, equal to path.
- `render_page(title)`: A full document with a doctype whose title contains title.
- `render_partial(target, swap = nil)`: An hx-partial with that hx-target, and that hx-swap when given. A block also checks its content.
- `have_html(within:, count:, strict:) { … }`: Blueprint-shaped requirements on the returned HTML.
- `have_row(Schema, **conditions)`: On the db handle: a row matching typed where conditions.

`have_row` is a macro over `Schema.query.where`, so an unknown or mistyped field fails compilation. Without conditions, it checks for any row.

**Corretto · matchers**

```crystal
created.should have_status(303)
created.should redirect_to("/books/1")
updated.should have_header("HX-Location", "/books/1")
shown.should render_page("Book")
db.should have_row(App::Book, title: "Dune", author: nil)
db.should_not have_row(App::Book, title: "Solaris")
```

The Corretto guide covers `have_html` and the block form of `render_partial` in depth.

[Test the HTML your app returns →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

## Fake third parties at the wire {#c-corretto-wire}

Corretto starts a local proxy for the suite and points `Caramel::Outbound`, the framework’s outbound HTTP client, at it. The proxy reads the real request bytes, records them, and answers from the latest matching stub. A stub matches the absolute URL, and the method when you give one. An unmatched request gets a 502 with `Unstubbed outbound request: METHOD URL`, so specs never reach the network.

**Corretto · wire stubs**

```crystal
Corretto.stub_wire("https://api.stripe.com/v1/customers", method: "POST")
  .to_return(status: 200, fixture: "stripe/customer.json")
Corretto.stub_wire("https://api.stripe.com/v1/charges")
  .to_return(status: 402, body: %({"error":"card_declined"}),
    headers: {"Content-Type" => "application/json"})
```

`to_return` takes a status, headers, and either `body:` or `fixture:`. A fixture is a relative path under `spec/fixtures/wire/`, and its extension sets the default `Content-Type`. `Corretto.wire_requests` lists the requests the proxy received in order. Stubs and recorded requests reset after each example. Only requests sent through `Caramel::Outbound` pass through the proxy.

Corretto forbids mocks. Loading a mocking library that defines `Mocks`, `Mock` or `Double`, or Spectator’s mocks, is a compile error. Before building, `frappe corretto` scans every Crystal file under `spec/` for calls such as `allow(`, `receive(`, `double(`, `instance_double(`, `mock(` and `.stub(`. It names each file and line, and refuses to run. Assert on requests, rows and rendered HTML instead.

## Drain background jobs {#c-corretto-jobs}

Specs start no Cold Brew workers. A job enqueued during an example waits in the example’s transaction until you drain its queue on the example’s connection.

**Corretto · after a request enqueues a job**

```crystal
Caramel::ColdBrew.drain_queue!(db, "default").should eq(1)
db.should have_row(App::Book, title: "Drained probe", author: "Cold Brew")
```

`drain_queue!` runs every due job synchronously, including jobs those jobs enqueue, and returns how many ran. Each job runs in a savepoint. A failed job follows its retry policy and is not retried in the same drain; `DrainFailure` then lists every failure. Pass `include_scheduled: true` to run jobs scheduled for later. A drain stops with `DrainLimitExceeded` after 1,000 jobs.

## Read a generated request spec {#c-corretto-example}

`frappe make resource Book title:string` writes a request spec that exercises the whole resource. This excerpt keeps its first steps.

**spec/requests/books_spec.cr · excerpt**

```crystal
require "../spec_helper"

describe "Books" do
  it "creates, reads, updates and deletes through CSRF-protected browser forms" do
    Corretto.session do |client, db|
      client.get("/books/new").should render_page("New book")
      created = client.post("/books", params: {"title" => "Example <title>"})
      record = App::Book.query.order_by(:id, :desc).first!(db)
      path = "/books/#{record.id}"
      created.should have_status(303)
      created.should redirect_to(path)
      db.should have_row(App::Book, id: record.id, title: "Example <title>")
      shown = client.follow_redirect
      shown.should render_page("Book")
      shown.should have_html { dl { dd { "Example <title>" } } }
    end
  end
end
```

The sample title contains `<title>`, so the HTML expectation also proves that the page escapes user text. The full spec goes on to check JSON, updates, forged requests, unknown fields and deletion.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Look up Crema →](https://caramelize.dev/docs/0.14.0/crema/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/corretto/
