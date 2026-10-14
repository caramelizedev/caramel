Reference / Corretto

# Test against the real thing.

Corretto runs request specs in-process against a real PostgreSQL database, rolls back every example, and fakes third parties at the wire.

| Contract | Value |
| --- | --- |
| Release | 0.14.0 |
| Needs | A generated application and Latte’s PostgreSQL |
| Covers | Spec helper, request client, matchers, wire stubs, job drains |
| Proved by | `frappe corretto` |

Learning it for the first time? The guide [Test the HTML your app returns](https://caramelize.dev/docs/0.14.0/testing-html/index.md) teaches expectations in order. This page lists every call and limit.

## Limits at a glance {#c-corretto-limits}

| Limit | Value |
| --- | --- |
| `.env.test` size, at most | 64 KiB |
| `--concurrency` workers | 1–8, default 1 |
| Body shown when a response matcher fails | first 800 characters |
| One drain, then `DrainLimitExceeded` | 1,000 jobs |

## Specs run only under frappe corretto {#c-corretto-setup}

A generated application has a spec helper that requires `caramel/corretto` and calls `Corretto.configure(App)` once. The application is built on the spec database, with the origin and secret that `frappe corretto` supplies.

**spec/spec_helper.cr**

```crystal
require "spec"
require "caramel/corretto"
require "../config/application"

Corretto.configure(App)
```

Spec workers start from a cleared environment. Put the test-only settings your application reads, such as a webhook secret, in the committed `.env.test`.

**.env.test**

```bash
WEBHOOK_SECRET=test-webhook-secret
```

| Condition | Outcome |
| --- | --- |
| Plain `crystal spec` | stops with `Run these specs with frappe corretto` |
| A database that is not this worker’s own spec database | stops, so development data is never touched |
| Your development `.env` | never reaches a worker |
| `.env.test` that is not a regular file, or is over 64 KiB | refuses |
| `.env.test` that sets `APP_ORIGIN`, `APP_SECRET`, `DATABASE_URL`, or a key starting `SPEC_`, `CARAMEL_` or `CORRETTO_` | refuses |

## Each worker gets its own database {#c-corretto-run}

A directory contributes its spec files. `frappe corretto` migrates the spec database once, and Latte then clones one database per worker from it.

**Terminal**

```bash
frappe corretto
frappe corretto spec/requests/books_spec.cr
frappe corretto spec/requests --concurrency=4
```

**Expect:** Spec files are dealt round-robin to the workers. Each worker runs its own compiled spec binary and prefixes its output lines, such as `[w1]`. The spec database is migrated once, and the worker databases are dropped afterwards.

Every example runs on one connection inside a transaction and a savepoint. Both are rolled back when the example ends, including the writes its requests and drained jobs made.

| Condition | Outcome |
| --- | --- |
| No paths | runs every `*_spec.cr` file under `spec` |
| A path outside the project | refuses |
| `--concurrency` outside 1 to 8 | refuses |
| `--concurrency` omitted | uses 1 worker |
| An example that changes the schema outside its transaction | warns and recreates the worker’s database from the migrated template |
| An example tagged `catalog` | runs unwrapped on a migration-role connection, and the database is always reset afterwards |
| File writes | are not rolled back; point your application’s storage at `Corretto.tmpdir`, a private directory removed after each example |

## A request sends one body {#c-corretto-client}

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

A request sends one body: URL-encoded `params:`, `params:` with `files:` as multipart, `json:` with any value, or raw `body:` text or bytes typed by your `Content-Type` header.

| Condition | Outcome |
| --- | --- |
| Any other mix of `params:`, `json:`, `body:` and `files:` | raises `Send one body: params: (with files: for multipart), json: or body:` |
| Any body besides `params:` on GET | raises |
| `params:` on GET | becomes the query |
| An Array value in `params:` | sends one key per item |
| A path that is not local, such as `/books` | raises |

## The client behaves like a browser {#c-corretto-browser}

The client acts as a browser on your application’s origin. It sends `Host` on every request and keeps a cookie jar from `Set-Cookie`.

| Condition | Outcome |
| --- | --- |
| post, put, patch, delete | adds the exact `Origin` and an `X-CSRF-Token` a page would submit |
| Headers you pass | override the automatic ones, which is how you test a forged request |
| A forged `X-CSRF-Token` or a foreign `Origin` | answers 403 |
| `client.follow_redirect` after a response with no `HX-Location` and no 3xx `Location` | raises |

**Corretto · forged requests**

```crystal
sample = {"title" => "Dune"}
forged = {"X-CSRF-Token" => "forged"}
foreign = {"Origin" => "https://attacker.example"}
client.post("/books", headers: forged, params: sample).should have_status(403)
client.post("/books", headers: foreign, params: sample).should have_status(403)
```

`client.follow_redirect` sends a GET to the last response’s `HX-Location`, or to its `Location` when the status is 3xx. `client.sign_in(user)` writes `user.id` as `user_id` into the signed session cookie, for an application whose sign-in stores `user_id`; an application with revocable sessions signs in through its login route instead.

[Revocable sessions →](https://caramelize.dev/cookbook/0.14.0/revocable-sessions/index.md)

## Matchers assert on responses and rows {#c-corretto-matchers}

Corretto’s matchers work with `should` and `should_not`.

| Matcher | Passes when |
| --- | --- |
| `have_status(status)` | The response status equals status. |
| `have_header(name, value = nil)` | The header is present; with a value, one of its values equals it. |
| `redirect_to(path)` | A 3xx Location, or an HX-Location, equal to path. |
| `render_page(title)` | A full document with a doctype whose title contains title. |
| `render_partial(target, swap = nil)` | An hx-partial with that hx-target, and that hx-swap when given. A block also checks its content. |
| `have_html(within:, count:, strict:) { … }` | Blueprint-shaped requirements on the returned HTML. |
| `have_row(Schema, **conditions)` | On the db handle: a row matching typed where conditions. |

| Condition | Outcome |
| --- | --- |
| A response matcher fails | shows the status, the headers and the first 800 characters of the body |
| `have_row` with an unknown or mistyped field | fails compilation |
| `have_row` without conditions | checks for any row |

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

## Third parties are faked at the wire {#c-corretto-wire}

Corretto starts a local proxy for the suite and points `Caramel::Outbound`, the framework’s outbound HTTP client, at it. The proxy reads the real request bytes, records them, and answers from the latest matching stub. A stub matches the absolute URL, and the method when you give one.

**Corretto · wire stubs**

```crystal
Corretto.stub_wire("https://api.stripe.com/v1/customers", method: "POST")
  .to_return(status: 200, fixture: "stripe/customer.json")
Corretto.stub_wire("https://api.stripe.com/v1/charges")
  .to_return(status: 402, body: %({"error":"card_declined"}),
    headers: {"Content-Type" => "application/json"})
```

`to_return` takes a status, headers, and either `body:` or `fixture:`. `Corretto.wire_requests` lists the requests the proxy received in order.

| Condition | Outcome |
| --- | --- |
| A request matching no stub | answers 502 `Unstubbed outbound request: METHOD URL`, so specs never reach the network |
| Several matching stubs | the latest answers |
| A fixture path | is relative to `spec/fixtures/wire/`, and its extension sets the default `Content-Type` |
| A request not sent through `Caramel::Outbound` | does not pass through the proxy |
| Stubs and recorded requests | reset after each example |

## Mocking libraries fail compilation {#c-corretto-mocks}

Corretto forbids mocks. Assert on requests, rows and rendered HTML instead.

| Condition | Outcome |
| --- | --- |
| A mocking library that defines `Mocks`, `Mock` or `Double`, or Spectator’s mocks | fails compilation |
| A spec file under `spec/` that calls `allow(`, `receive(`, `double(`, `instance_double(`, `mock(` or `.stub(` | `frappe corretto` refuses to run before building, naming the file and line |

## Specs start no workers {#c-corretto-jobs}

Specs start no Cold Brew workers. A job enqueued during an example waits in the example’s transaction until you drain its queue on the example’s connection.

**Corretto · after a request enqueues a job**

```crystal
Caramel::ColdBrew.drain_queue!(db, "default").should eq(1)
db.should have_row(App::Book, title: "Drained probe", author: "Cold Brew")
```

| Condition | Outcome |
| --- | --- |
| `drain_queue!` | runs every due job synchronously, including jobs those jobs enqueue, and returns how many ran |
| Each job | runs in a savepoint |
| A failed job | follows its retry policy and is not retried in the same drain; `DrainFailure` then lists every failure |
| `include_scheduled: true` | also runs jobs scheduled for later |
| Jobs still due after 1,000 runs | raises `DrainLimitExceeded` |

Prove it

## Run a generated request spec {#c-corretto-example}

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

**Terminal · inside the application**

```bash
frappe corretto spec/requests/books_spec.cr
```

**Passing:** Every example passes. The sample title contains `<title>`, so the HTML expectation also proves that the page escapes user text. The full spec goes on to check JSON, updates, forged requests, unknown fields and deletion.

[← Cold Brew](https://caramelize.dev/docs/0.14.0/cold-brew/index.md) · [Look up Crema →](https://caramelize.dev/docs/0.14.0/crema/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/corretto/
