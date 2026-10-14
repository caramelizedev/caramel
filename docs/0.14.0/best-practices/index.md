Guides / Best practices

# Build it the Caramel way.

The conventions that keep a Caramel application typed, safe, and easy to change, and the checks that hold it to them.

| Contract | Value |
| --- | --- |
| Covers | Placing changes, contracts, changesets, migrations, escaping, CSRF, jobs, tests, catalogs and lint rules |
| You will have | An application that stays typed, safe and easy to change |
| Proved by | `frappe check` · `frappe lint` · `frappe corretto` |

## The guide in five stages {#c-practices-map}

10 sections · read in order the first time

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

Stage 1 · Start

## Give every change its home {#c-practices-home}

Each kind of change has one place. Routes live in `config/routes.cr`, actions and their contracts in `app/actions/`, stored shapes in `app/models/`, write rules in `app/changesets/`, and a SweetTalk domain in `app/domain/`. HTML lives in `app/views/`, background work in `app/jobs/`, translations in `app/locales/`, and request specs in `spec/requests/`.

Your application’s files are the extension point. When the public API cannot do what a task needs, name the gap instead of patching framework code.

[Find the file for a change →](https://caramelize.dev/docs/0.14.0/project-map/index.md)

## Declare every input {#c-practices-inputs}

Read request data only through the action’s contract. Give each field its type, and bounds or a default where they apply.

| Condition | Outcome |
| --- | --- |
| A submitted field the contract does not declare | answers 422 |
| The same, in the query of a GET or HEAD request | is not an error |
| Route parameter with no matching field | fails compilation |

`frappe check` prints the line that adds a missing field.

**app/actions/books/create.cr · contract**

```crystal
contract do
  field title : String, min: 1, max: 200
  field isbn : String
  field rating : Int32?, min: 1, max: 5
end
```

[Read the contract reference →](https://caramelize.dev/docs/0.14.0/routes-and-contracts/index.md)

Stage 2 · Data

## Write through changesets {#c-practices-writes}

Every insert and update goes through a changeset, so its rules run for every caller. Put validations in `validate(cs)`. Declare `unique_constraint` for each unique index. Show the errors with the form, or with `render_errors`.

| Condition | Outcome |
| --- | --- |
| Duplicate on a unique index, with `unique_constraint` declared | adds an error on the field |
| The same duplicate without it | raises a database exception |

**app/changesets/book.cr**

```crystal
class Book::Changeset < SugarORM::Changeset(App::Book)
  param title : String
  param isbn : String

  def validate(cs)
    cs.validate_presence(:title)
    cs.validate_length(:title, max: 200)
    cs.unique_constraint(:isbn)
  end
end
```

## Preload, and migrate in reviewed steps {#c-practices-data}

Preload every association a page reads. To change stored data, edit the schema first, derive the migration, read its SQL, then apply it. Rehearse a risky change on a database branch.

| Condition | Outcome |
| --- | --- |
| Association a page reads without a preload | fails compilation, reported as `N_PLUS_ONE` |
| Migration that would lock a busy table | refuses |

**Terminal**

```bash
frappe db diff --name add_rating_to_books
```

**Expect:** Writes the migration to `db/migrations/` and prints `Wrote PATH`.

**Terminal**

```bash
frappe migrate
```

**Expect:** Prints `Applied N migrations.`, then `The database matches the declared schema.`

**Terminal**

```bash
frappe db branch create rating_trial
```

**Expect:** Prints the branch’s database URL.

[Read the SugarORM reference →](https://caramelize.dev/docs/0.14.0/sugarorm/index.md)

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

[Review the security defaults →](https://caramelize.dev/docs/0.14.0/security/index.md)

Stage 4 · Work

## Make background work safe to repeat {#c-practices-jobs}

Enqueue a job in the same transaction as the write it follows, so both commit or neither does. Pass identifiers, not records, and load fresh data in `perform`. A job runs at least once: give each external call a stable identifier the receiving service can deduplicate. Keep retry and failure hooks short. A recurring schedule runs once per period however many processes run it, so its block should only enqueue the real work.

**app/actions/books/create.cr · the write and its job**

```crystal
def handle(contract : Contract)
  changes = App::Book::Changeset.new(title: contract.title, isbn: contract.isbn)
  SugarORM::Repo.transaction do
    SugarORM::Repo.insert(changes)
    App::SendReceipt.enqueue(book_id: changes.record.id) if changes.saved?
  end
  return render_errors(changes.errors) unless changes.saved?
  {record: changes.record}
end
```

## Test what users observe {#c-practices-tests}

Write request specs that drive the application through Corretto against real PostgreSQL. Assert the rendered HTML with `have_html`, stored rows with `have_row`, and statuses and headers, with at least one failure case for each rule. Fake a third-party service at the wire with `Corretto.stub_wire`. Drain queues with `Caramel::ColdBrew.drain_queue!`, then assert what the job changed.

| Condition | Outcome |
| --- | --- |
| A mocking library compiled beside Corretto | fails compilation |

[Read the Corretto reference →](https://caramelize.dev/docs/0.14.0/corretto/index.md)

Stage 5 · Style

## Keep user-facing text in catalogs {#c-practices-text}

Once an application has locales, write user-facing text as `t.` messages. Use `%{name}` placeholders instead of Crystal interpolation, so every locale has to keep them. Run `frappe translations` in CI to see what each locale still takes from the default, and pass `Caramel.language` to jobs that produce text.

## Write code that reads like short sentences {#c-practices-style}

`frappe lint` holds the application to Caramel’s rule set: descriptive names, no service nouns such as `InvitationService`, short blocks, positive conditions, and actions small enough to read as one thought. Put the verb on its subject instead of a service: a method on the model, a changeset, or a job. `frappe format` applies the pinned formatter.

Prove it

## Prove every change {#c-practices-proof}

Run the same checks before every commit. An agent can read `frappe check --agent`: its diagnostics include the line that fixes a contract mismatch or a missing preload. Add `frappe translations` once the application has locales.

**Terminal · before every commit**

```bash
frappe check
frappe lint
frappe corretto
```

**Passing:** `frappe check` prints `✓ Type check passed`, `frappe lint` exits 0 and `frappe corretto` ends with `Corretto: N of N workers passed`.

[← Project map](https://caramelize.dev/docs/0.14.0/project-map/index.md) · [Declare routes and contracts →](https://caramelize.dev/docs/0.14.0/routes-and-contracts/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/best-practices/
