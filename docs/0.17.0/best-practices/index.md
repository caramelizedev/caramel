Guides / Best practices

# Build it the Caramel way.

The ten rules a Caramel application keeps for its inputs, writes, HTML, jobs, tests and text, and the checks that hold it to them.

| Contract | Value |
| --- | --- |
| Covers | Placing changes, contracts, changesets, migrations, escaping, CSRF, jobs, tests, catalogs and lint rules |
| You will have | An application whose inputs, writes, HTML, jobs and text follow the ten rules below, checked by `frappe check`, `frappe lint` and `frappe corretto` |
| Proved by | `frappe check` · `frappe lint` · `frappe corretto` |

## The guide in six stages {#c-practices-map}

12 sections · read in order the first time

- **1 · Start**

  - [Give every change its home](#c-practices-home)
  - [Declare every input](#c-practices-inputs)
- **2 · Data**

  - [Write through changesets](#c-practices-writes)
  - [Preload, and migrate in reviewed steps](#c-practices-data)
- **3 · Browser**

  - [Keep HTML escaped](#c-practices-html)
  - [Keep the browser protections on](#c-practices-trust)
- **4 · Work**

  - [Make background work safe to repeat](#c-practices-jobs)
  - [Test what users observe](#c-practices-tests)
- **5 · Style**

  - [Keep user-facing text in catalogs](#c-practices-text)
  - [Write code that reads like short sentences](#c-practices-style)
- **6 · Limits**

  - [What does not compile](#c-practices-compile)
  - [Not covered yet](#c-practices-gaps)

The code on this page extends the bookshelf of [Your first application](https://caramelize.dev/docs/0.17.0/getting-started/index.md): a Book with `title` and `author`, to which this page adds a `rating` and a receipt job.

Stage 1 · Start

## Give every change its home {#c-practices-home}

Each kind of change has one place, and [Project structure](https://caramelize.dev/docs/0.17.0/project-map/index.md) lists them. Your application’s files are the extension point. When the public API cannot do what a task needs, name the gap, in an issue or in `AGENTS.md`, instead of patching `lib/caramel`: the next `shards install` would undo the patch.

## Declare every input {#c-practices-inputs}

Read request data only through the action’s contract. Give each field its type, and bounds or a default where they apply. The outcomes of an undeclared field and of a route parameter without a field are in the [contract reference](https://caramelize.dev/docs/0.17.0/routes-and-contracts/index.md); `frappe check` prints the line that adds a missing field.

**app/actions/books/create.cr · contract, with the rating this page adds**

```crystal
contract do
  field title : String, min: 1, max: 200
  field author : String, min: 1, max: 200
  field rating : Int32?, min: 1, max: 5
end
```

Stage 2 · Data

## Write through changesets {#c-practices-writes}

Every insert and update goes through a changeset, so its rules run for every caller. Put validations in `validate(cs)`. Declare `unique_constraint` for each unique index. Show the errors with the form, or with `render_errors`.

| Condition | Outcome |
| --- | --- |
| Duplicate on a unique index, with `unique_constraint` declared | adds an error on the field |
| The same duplicate without it | raises a database exception |

**app/changesets/book.cr · for a Book generated with title:string:unique**

```crystal
class Book::Changeset < SugarORM::Changeset(App::Book)
  param title : String
  param author : String
  param rating : Int32?

  def validate(cs)
    cs.validate_presence(:title)
    cs.validate_length(:title, max: 200)
    cs.unique_constraint(:title)
  end
end
```

## Preload, and migrate in reviewed steps {#c-practices-data}

Preload every association a page reads. To change stored data, edit the schema first, derive the migration, read its SQL, then apply it. Rehearse a change you cannot undo, such as dropping a column, on a database branch.

| Condition | Outcome |
| --- | --- |
| Association a page reads without a preload | fails compilation, reported as `N_PLUS_ONE` |
| A migration with `CREATE INDEX` on an existing table, which blocks its writes while the index builds | refuses; `frappe db diff` writes `CREATE INDEX CONCURRENTLY` in a migration of its own |

**app/models/book.cr · the schema edit, inside schema "books"**

```crystal
field rating : Int32?
```

**Terminal · inside the application, after the schema edit**

```bash
frappe db diff --name add_rating_to_books
```

**Expect:** Writes the migration to `db/migrations/` and prints `Wrote PATH`. Without the schema edit it prints `already matches the declared schema; no migration was written`, and a second run after migrating prints the same.

**Terminal · inside the application**

```bash
frappe migrate
```

**Expect:** Prints `Applied N migrations.`, then `The database matches the declared schema.`

**Terminal · inside the application**

```bash
frappe db branch create rating_trial
```

**Expect:** Prints the branch’s database URL. `frappe dev --branch rating_trial` then runs the application against the copy; the development database is untouched.

[Read the SugarORM reference →](https://caramelize.dev/docs/0.17.0/sugarorm/index.md)

Stage 3 · Browser

## Keep HTML escaped {#c-practices-html}

Views escape every text value and attribute. Mark a value as `Caramel::HTML::Safe` only when your own code built it, such as the result of `markup { … }`; never wrap user input. Update part of a page with an htmx fragment, `morph`, or `partials` instead of client-side state, and use an island only where a widget needs state of its own.

## Keep the browser protections on {#c-practices-trust}

Every write a browser sends carries the CSRF token: forms include the hidden `_csrf` field, and the generated layout sends `X-CSRF-Token` with htmx requests. Turn CSRF off only for a route whose `ingress` names an authenticator for a credential a browser never attaches on its own, such as a signature or a bearer token. Verify a webhook’s signature over its `raw_body` with a constant-time comparison before reading it.

| Condition | Outcome |
| --- | --- |
| `ingress` sets `csrf: false` and names no authenticator | fails compilation |
| `redirect_to` given a destination that is not a path on your site | refuses |

Store a user-supplied destination through a changeset that calls `validate_url`, so `redirect_external` can follow it.

[Review the security defaults →](https://caramelize.dev/docs/0.17.0/security/index.md)

Stage 4 · Work

## Make background work safe to repeat {#c-practices-jobs}

Enqueue a job in the same transaction as the write it follows, so both commit or neither does. Pass identifiers, not records, and load fresh data in `perform`. A job runs at least once: give each external call a stable identifier the receiving service can deduplicate. A retry or failure hook only records or enqueues; it does no work of its own. A recurring schedule runs once per period however many processes run it, so its block should only enqueue the real work.

**app/jobs/send_receipt.cr · the job this page adds**

```crystal
struct App::SendReceipt < Caramel::ColdBrew::Job
  param book_id : Int64

  def perform
    # Load the book by book_id and send its receipt.
  end
end
```

**app/actions/books/create.cr · handle, rewritten to enqueue the job beside the write**

```crystal
def handle(contract : Contract)
  changes = App::Book::Changeset.new(title: contract.title, author: contract.author)
  SugarORM::Repo.transaction do
    SugarORM::Repo.insert(changes)
    App::SendReceipt.enqueue(book_id: changes.record.id) if changes.saved?
  end
  return render_errors(changes.errors) unless changes.saved?
  {record: changes.record}
end
```

## Test what users observe {#c-practices-tests}

Write request specs that drive the application through Corretto against real PostgreSQL. Assert the rendered HTML with `have_html`, stored rows with `have_row`, and statuses and headers, with at least one failure case for each rule. Fake a third-party service at the wire with `Corretto.stub_wire`. Drain queues with `Caramel::ColdBrew.drain_queue!`, then assert what the job changed. Corretto refuses a mocking library; the [Corretto reference](https://caramelize.dev/docs/0.17.0/corretto/index.md) says how.

Stage 5 · Style

## Keep user-facing text in catalogs {#c-practices-text}

Once an application has locales, write user-facing text as `t.` messages. Use `%{name}` placeholders instead of Crystal interpolation, so every locale has to keep them. Run `frappe translations` in CI to see what each locale still takes from the default, and pass `Caramel.language` to jobs that produce text.

## Write code that reads like short sentences {#c-practices-style}

`frappe lint` holds the application to Caramel’s rule set: descriptive names, no service nouns such as `InvitationService`, positive conditions, a cyclomatic complexity of at most 10 per method, no `dump` left behind, and no run-time read of a path built from `__DIR__`. Every other rule is Ameba 1.7.0’s default. Put the verb on its subject instead of a service: a method on the model, a changeset, or a job. `frappe format` applies the pinned formatter.

Limits

## What does not compile {#c-practices-compile}

| Condition | Outcome |
| --- | --- |
| A route parameter with no matching contract field | fails compilation |
| An association a page reads without a preload | fails compilation, reported as `N_PLUS_ONE` |
| `ingress` with `csrf: false` and no authenticator | fails compilation |
| A mocking library compiled beside Corretto | fails compilation |
| A method whose cyclomatic complexity passes 10 | fails `frappe lint`, not compilation |

## Not covered yet {#c-practices-gaps}

- No rule here is checked by a page fixture; the snippets extend the bookshelf by hand and no check builds them.
- Browser tests under `spec/system/` and file storage under `storage/` have no conventions yet.

Prove it

## Prove every change {#c-practices-proof}

Run the same checks before every commit. An agent can read `frappe check --agent`: its diagnostics include the line that fixes a contract mismatch or a missing preload. Add `frappe translations` once the application has locales.

**Terminal · before every commit**

```bash
frappe check
frappe lint
frappe corretto
```

**Passing:** `frappe check` exits 0, `frappe lint` exits 0 and `frappe corretto` ends with `Corretto: N of N workers passed`.

[← Project map](https://caramelize.dev/docs/0.17.0/project-map/index.md) · [Declare routes and contracts →](https://caramelize.dev/docs/0.17.0/routes-and-contracts/index.md)

Caramel 0.17.0 · https://caramelize.dev/docs/0.17.0/best-practices/
