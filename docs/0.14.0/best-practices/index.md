Guides / Best practices

# Build it the Caramel way.

The conventions that keep a Caramel application typed, safe, and easy to change, and the checks that hold it to them.

## Give every change its home {#c-practices-home}

Each kind of change has one place. Routes live in `config/routes.cr`, actions and their contracts in `app/actions/`, stored shapes in `app/models/`, write rules in `app/changesets/`, and a SweetTalk domain in `app/domain/`. HTML lives in `app/views/`, background work in `app/jobs/`, translations in `app/locales/`, and request specs in `spec/requests/`.

Your application’s files are the extension point. When the public API cannot do what a task needs, name the gap instead of patching framework code.

[Find the file for a change →](https://caramelize.dev/docs/0.14.0/project-map/index.md)

## Declare every input {#c-practices-inputs}

Read request data only through the action’s contract. Give each field its type, and bounds or a default where they apply. A submitted field the contract does not declare is an error, except in the query of a GET or HEAD request. The compiler checks that every route parameter has a matching field, and `frappe check` prints the line that adds a missing one.

**app/actions/books/create.cr · contract**

```crystal
contract do
  field title : String, min: 1, max: 200
  field isbn : String
  field rating : Int32?, min: 1, max: 5
end
```

[Read the contract reference →](https://caramelize.dev/docs/0.14.0/routes-and-contracts/index.md)

## Write through changesets {#c-practices-writes}

Every insert and update goes through a changeset, so its rules run for every caller. Put validations in `validate(cs)`. Declare `unique_constraint` for each unique index: a duplicate then becomes an error on the field instead of a database exception. Show the errors with the form, or with `render_errors`.

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

Preload every association a page reads; `frappe check` reports a missing preload as `N_PLUS_ONE`. To change stored data, edit the schema first, derive the migration, read its SQL, then apply it. The migration linter refuses changes that would lock busy tables. Rehearse a risky change on a database branch.

**Terminal**

```bash
frappe db diff --name add_rating_to_books
frappe migrate
frappe db branch create rating_trial
```

[Read the SugarORM reference →](https://caramelize.dev/docs/0.14.0/sugarorm/index.md)

## Keep HTML escaped {#c-practices-html}

Views escape every text value and attribute. Mark a value as `Caramel::HTML::Safe` only when your own code built it, such as the result of `markup { … }`; never wrap user input. Update part of a page with an htmx fragment, `morph`, or `partials` instead of client-side state, and use an island only where a widget needs state of its own.

## Keep the browser protections on {#c-practices-trust}

Every write a browser sends carries the CSRF token: forms include the hidden `_csrf` field, and the generated layout sends `X-CSRF-Token` with htmx requests. Turn CSRF off only for a route whose `ingress` names an authenticator for a credential a browser never attaches on its own, such as a signature or a bearer token; Caramel refuses `csrf: false` without one. Verify a webhook’s signature over its `raw_body` with a constant-time comparison before reading it.

`redirect_to` accepts only paths on your site. Store a user-supplied destination through a changeset that calls `validate_url`, so `redirect_external` can follow it.

[Review the security defaults →](https://caramelize.dev/docs/0.14.0/security/index.md)

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

Write request specs that drive the application through Corretto against real PostgreSQL. Assert the rendered HTML with `have_html`, stored rows with `have_row`, and statuses and headers, with at least one failure case for each rule. Fake a third-party service at the wire with `Corretto.stub_wire`; Corretto refuses to compile beside a mocking library. Drain queues with `Caramel::ColdBrew.drain_queue!`, then assert what the job changed.

[Read the Corretto reference →](https://caramelize.dev/docs/0.14.0/corretto/index.md)

## Keep user-facing text in catalogs {#c-practices-text}

Once an application has locales, write user-facing text as `t.` messages. Use `%{name}` placeholders instead of Crystal interpolation, so every locale has to keep them. Run `frappe translations` in CI to see what each locale still takes from the default, and pass `Caramel.language` to jobs that produce text.

## Write code that reads like short sentences {#c-practices-style}

`frappe lint` holds the application to Caramel’s rule set: descriptive names, no service nouns such as `InvitationService`, short blocks, positive conditions, and actions small enough to read as one thought. Put the verb on its subject instead of a service: a method on the model, a changeset, or a job. `frappe format` applies the pinned formatter.

## Prove every change {#c-practices-proof}

Run the same checks before every commit. An agent can read `frappe check --agent`: its diagnostics include the line that fixes a contract mismatch or a missing preload. Add `frappe translations` once the application has locales.

**Terminal · before every commit**

```bash
frappe check
frappe lint
frappe corretto
```

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Declare routes and contracts →](https://caramelize.dev/docs/0.14.0/routes-and-contracts/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/best-practices/
