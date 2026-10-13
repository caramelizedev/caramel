Guides / Multi-tenancy

# Serve many accounts from one app.

Give each account its own address and its own rows, with queries that refuse to run outside a tenant.

## Enable tenancy {#c-tenancy-enable}

Multi-tenancy is opt-in, and a plain application does not compile it. Name the model that owns the data; any singular model name works.

**Terminal · inside your application**

```bash
frappe make tenancy Account
frappe migrate
```

The command writes the `Account` model (name, slug, timestamps, a unique slug index), its changeset, the `create_accounts` migration, a sign-up page at `/accounts/new`, a home page at `/SLUG` and a request spec. It requires `caramel/tenancy` after `caramel` in `config/application.cr`, adds the tenant block to `config/routes.cr` and `Caramel.resource_paths :accounts, :account` to `config/paths.cr`, and adds the `account` and `tenant_session` spec helpers. Sign up at `/accounts/new`; a new account redirects to its home.

## Route inside the tenant {#c-tenancy-routes}

The tenant block names the tenant model and the String field its address uses. Routes inside it live under the slug, so `/books` answers at `/acme/books`. A router has one tenant block.

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

`frappe routes` lists tenant routes as `/:tenant/books`. Two mistakes fail compilation: a central route other than `/` that starts with a parameter, and a tenant route that starts with a central route’s first segment.

## Generate tenant resources {#c-tenancy-resources}

After tenancy is enabled, `frappe make resource` writes resources that belong to the tenant: routes inside the block, `tenant account : Account` in the model, and a request spec. Pass `--central` for a resource every tenant shares; it is identical to a plain application’s.

**Terminal · inside your application**

```bash
frappe make resource Note body:string
frappe make resource Tag label:string --central
```

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

- Queries, `find`, `count`, `exists?`, `delete_all`, preloads, updates and deletes see only the bound tenant’s rows, and inserts are stamped with it. Another tenant’s id answers 404, like an unknown one.
- A unique index is unique per tenant, so two accounts may share an ISBN.
- A `belongs_to` to another tenanted schema becomes a composite foreign key: PostgreSQL refuses a reference to another tenant’s row, even from raw SQL.
- Scoping fails closed. A tenanted query with no tenant bound raises `SugarORM::Tenancy::Missing`, such as “App::Book is tenanted, but no tenant is bound.”
- `Caramel::Tenancy.without { … }` reaches every tenant’s rows on purpose. Creating a tenanted row inside it still raises.
- Raw `SugarORM.sql` is not scoped.

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

A Cold Brew job enqueued in a tenant runs in it; if that tenant was deleted, the job fails with `Caramel::Tenancy::Gone`. A `spawn`ed fiber starts with no tenant, so wrap its work in `with`. Cache keys and PubSub channels are prefixed per tenant with `t<id>:`, and a prefixed channel name must stay within 63 characters.

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

## Slugs and membership {#c-tenancy-slugs}

`validate_tenant_slug` accepts a lowercase DNS label: letters, digits and hyphens, 1 to 63 characters, with no leading or trailing hyphen. It refuses a central route’s first segment, such as `health` or `accounts`, and a locale prefix code.

Tenancy decides which rows a request sees, not who may act in a tenant. Check membership in the application, for example with `ingress authenticate: :member?`.

## Add tenancy to existing data {#c-tenancy-existing}

On a populated table, `frappe db diff` halts at the new NOT NULL column. Add and backfill the column by hand, build its index in a migration of its own, then let `frappe db diff` write the keys. Drain every queue before the first deploy with tenancy: a job enqueued without a tenant runs with none, and fails on tenanted rows with `SugarORM::Tenancy::Missing`.

[Read the multi-tenancy design and the exact steps ↗](https://github.com/caramelizedev/caramel/blob/main/docs/decisions/0025-multi-tenancy.md)

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/multi-tenancy/
