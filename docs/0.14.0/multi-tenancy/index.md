Guides / Multi-tenancy

# Serve many accounts from one app.

Give each account its own address and its own rows, with queries that refuse to run outside a tenant.

| Contract | Value |
| --- | --- |
| Needs | A configured application and a singular model to own the data, such as `Account` |
| You will have | Each account at its own address with its own rows, and queries that refuse to run outside a tenant |
| Proved by | `frappe routes` · `frappe corretto` |

## The guide in five stages {#c-tenancy-map}

9 sections · read in order the first time

- **1 · Start**

  - [Enable tenancy](#c-tenancy-enable)
- **2 · Model**

  - [Route inside the tenant](#c-tenancy-routes)
  - [Generate tenant resources](#c-tenancy-resources)
  - [Declare tenanted data](#c-tenancy-schema)
- **3 · Use**

  - [Use the tenant in actions and views](#c-tenancy-views)
  - [Carry the tenant into background work](#c-tenancy-background)
- **4 · Operate**

  - [Validate slugs and check membership](#c-tenancy-slugs)
  - [Add tenancy to existing data](#c-tenancy-existing)
- **5 · Limits**

  - [What does not compile](#c-tenancy-refusals)

Stage 1 · Start

## Enable tenancy {#c-tenancy-enable}

Multi-tenancy is opt-in, and a plain application does not compile it. Name the model that owns the data; any singular model name works.

**Terminal · inside your application**

```bash
frappe make tenancy Account
frappe migrate
```

**Expect:** `frappe make tenancy` prints a `Generated` line for each file it writes and ends with a `Next:` line that names `frappe migrate` and the sign-up page at `/accounts/new`. `frappe migrate` applies `create_accounts`.

The command writes the `Account` model (name, slug, timestamps, a unique slug index), its changeset, the `create_accounts` migration, a sign-up page at `/accounts/new`, a home page at `/SLUG` and a request spec. It requires `caramel/tenancy` after `caramel` in `config/application.cr`, adds the tenant block to `config/routes.cr` and `Caramel.resource_paths :accounts, :account` to `config/paths.cr`, and adds the `account` and `tenant_session` spec helpers. Sign up at `/accounts/new`; a new account redirects to its home.

Stage 2 · Model

## Route inside the tenant {#c-tenancy-routes}

The tenant block names the tenant model and the String field its address uses. Routes inside it live under the slug, so `/books` answers at `/acme/books`.

**config/routes.cr · excerpt**

```crystal
Caramel::Router.draw do
  get "/", App::Home::Show
  post "/accounts", App::Accounts::Create
  tenant App::Account, by: :slug do
    get "/", App::Accounts::Home
    get "/books", App::Books::Index
  end
end
```

`frappe routes` lists tenant routes as `/:tenant/books`.

## Generate tenant resources {#c-tenancy-resources}

After tenancy is enabled, `frappe make resource` writes resources that belong to the tenant: routes inside the block, `tenant account : Account` in the model, and a request spec. Pass `--central` for a resource every tenant shares; it is identical to a plain application’s.

**Terminal · inside your application**

```bash
frappe make resource Note body:string
frappe make resource Tag label:string --central
```

**Expect:** `Note`’s routes sit inside the tenant block, so `frappe routes` lists them as `/:tenant/notes`; `Tag`’s stay central at `/tags`.

## Declare tenanted data {#c-tenancy-schema}

The `tenant` statement adds the `account_id` column and scopes the schema to the bound tenant. The column is never a changeset param.

**app/models/book.cr · schema excerpt**

```crystal
schema "books" do
  field id : Int64, primary: true
  tenant account : Account
  field isbn : String
  belongs_to author : Author
  timestamps
  index :isbn, unique: true
end
```

| Condition | Outcome |
| --- | --- |
| A tenanted query with no tenant bound, such as “App::Book is tenanted, but no tenant is bound.” | raises `SugarORM::Tenancy::Missing` |
| Another tenant’s id | answers 404, like an unknown one |
| A `belongs_to` to a row of another tenant, even from raw SQL | PostgreSQL refuses it |
| Creating a tenanted row inside `Caramel::Tenancy.without` | raises |

- Queries, `find`, `count`, `exists?`, `delete_all`, preloads, updates and deletes see only the bound tenant’s rows, and inserts are stamped with it.
- A unique index is unique per tenant, so two accounts may share an ISBN.
- A `belongs_to` to another tenanted schema becomes a composite foreign key.
- `Caramel::Tenancy.without { … }` reaches every tenant’s rows on purpose.
- Raw `SugarORM.sql` is not scoped.

Stage 3 · Use

## Use the tenant in actions and views {#c-tenancy-views}

Actions and views expose `tenant`, the request’s tenant record, and `tenant_path`, a path under its prefix. Generated resource path helpers already add the prefix.

**Inside a view’s blueprint · in acme**

```crystal
h1 { tenant.name }
a(href: tenant_path("/")) { "Home" }  # /acme
a(href: books_path) { "Books" }       # /acme/books
```

With locale prefixes, the tenant comes first: `/acme/fr/books`. The language switcher keeps the tenant prefix.

## Carry the tenant into background work {#c-tenancy-background}

Outside a request, bind a tenant explicitly. `Caramel::Tenancy.current` and `current?` read the bound one.

**A task or job · account is a loaded App::Account**

```crystal
Caramel::Tenancy.with(account) do
  App::Book.query.count
end

Caramel::Tenancy.each do |account|
  # Runs once per tenant, bound.
end
```

A Cold Brew job enqueued in a tenant runs in it. A `spawn`ed fiber starts with no tenant, so wrap its work in `with`. Cache keys and PubSub channels are prefixed per tenant with `t<id>:`.

| Condition | Outcome |
| --- | --- |
| A Cold Brew job whose tenant was deleted before it ran | fails with `Caramel::Tenancy::Gone` |
| A prefixed PubSub channel name over 63 characters | raises ArgumentError |

Stage 4 · Operate

## Validate slugs and check membership {#c-tenancy-slugs}

`validate_tenant_slug` checks the address a tenant gets:

| Condition | Outcome |
| --- | --- |
| A slug that is not a lowercase DNS label (letters, digits and hyphens, 1 to 63 characters, no leading or trailing hyphen) | `validate_tenant_slug` refuses it |
| A slug equal to a central route’s first segment, such as `health` or `accounts` | `validate_tenant_slug` refuses it |
| A slug equal to a locale prefix code | `validate_tenant_slug` refuses it |

Tenancy decides which rows a request sees, not who may act in a tenant. Check membership in the application, for example with `ingress authenticate: :member?`.

## Add tenancy to existing data {#c-tenancy-existing}

On a populated table, add and backfill the new NOT NULL column by hand, build its index in a migration of its own, then let `frappe db diff` write the keys. Drain every queue before the first deploy with tenancy.

| Condition | Outcome |
| --- | --- |
| `frappe db diff` on a populated table that gains a NOT NULL column | halts |
| A job enqueued without a tenant, run on tenanted rows | fails with `SugarORM::Tenancy::Missing` |

[Read the multi-tenancy design and the exact steps ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0025-multi-tenancy.md)

Stage 5 · Limits

## What does not compile {#c-tenancy-refusals}

A router has one tenant block. Each mistake below stops the build.

| Condition | Outcome |
| --- | --- |
| A central route other than `/` that starts with a parameter | fails compilation |
| A tenant route that starts with a central route’s first segment | fails compilation |
| A router with a second tenant block | fails compilation |

Prove it

## Test isolation {#c-tenancy-testing}

`tenant_session("acme")` opens a Corretto session in a new account, and the example’s queries see only its rows. `account(db, "globex")` creates a second account to prove isolation.

**spec/requests/notes_spec.cr · inside an example**

```crystal
tenant_session("acme") do |client, db|
  record = App::Note.create!(db, body: "Plan")
  account(db, "globex")
  client.get("/globex/notes/#{record.id}").should have_status(404)
end
```

**Terminal · inside your application**

```bash
frappe routes
frappe corretto spec/requests/notes_spec.cr
```

**Passing:** `frappe routes` lists `/:tenant/notes` beside the central `/tags`. The example passes: a request from `acme` for `globex`’s note answers 404.

[← Internationalization](https://caramelize.dev/docs/0.14.0/internationalization/index.md) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/multi-tenancy/
