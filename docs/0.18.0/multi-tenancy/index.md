Guides / Multi-tenancy

# Serve many accounts from one app.

Give each account its own `/SLUG` path and its own rows, with queries that refuse to run outside a tenant.

| Contract | Value |
| --- | --- |
| Needs | An application that has run `frappe migrate`, and a singular model name to own the data, such as `Account` |
| You will have | Each account under its own `/SLUG` path with its own rows, and queries that refuse to run outside a tenant |
| Proved by | `frappe routes` · `frappe corretto` |

## The guide in five stages {#c-tenancy-map}

10 sections · read in order the first time

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
  - [Not covered yet](#c-tenancy-gaps)

Stage 1 · Start

## Enable tenancy {#c-tenancy-enable}

Multi-tenancy is opt-in, and a plain application does not compile it. Name the model that owns the data; any singular model name works.

**Terminal · inside your application**

```bash
frappe make tenancy Account
frappe migrate
```

**Expect:** `frappe make tenancy` prints a `Generated` line for each file it writes and ends with a `Next:` line that names `frappe migrate` and the sign-up page at `/accounts/new`. With a SweetTalk domain present, the `Next:` line adds that each domain in `app/domain/` now names `App::Account`. `frappe migrate` applies `create_accounts`.

The command writes the `Account` model (name, slug, timestamps, a unique slug index, a `json` line), its changeset, the `create_accounts` migration, a sign-up page at `/accounts/new`, a home page at `/SLUG` and a request spec. It requires `caramel/tenancy` after `caramel` in `config/application.cr`, adds the tenant block to `config/routes.cr` and `Caramel.resource_paths :accounts, :account` to `config/paths.cr`, and adds the `account` and `tenant_session` spec helpers. In every `app/domain/*.cr` it adds `tenant App::Account` after `include SweetTalk`, because a program that requires `caramel/tenancy` refuses a domain that does not name its tenant. Sign up at `/accounts/new`; a new account redirects to its home.

[Share a domain between tenants →](https://caramelize.dev/docs/0.18.0/sweettalk/index.md)

Stage 2 · Model

## Route inside the tenant {#c-tenancy-routes}

The tenant block names the tenant model and the String field whose value is the first path segment. Routes inside it live under the slug, so `/notes` answers at `/acme/notes`. This is the block `frappe make tenancy Account` writes, with the Note resource of the next section inside it:

**config/routes.cr · after make tenancy and make resource Note**

```crystal
Caramel::Router.draw do
  get "/", App::Home::Show
  get "/health", App::Health::Show
  get "/accounts/new", App::Accounts::New
  post "/accounts", App::Accounts::Create
  # Frappé resource routes

  tenant App::Account, by: :slug do
    get "/", App::Accounts::Home
    get "/notes", App::Notes::Index
    # Frappé tenant routes
  end
end
```

`frappe routes` lists tenant routes as `/:tenant/notes`. A tenant is chosen by its path prefix only: `acme.example.com` selects nothing.

## Generate tenant resources {#c-tenancy-resources}

After tenancy is enabled, `frappe make resource` writes resources that belong to the tenant: routes inside the block, `tenant account : Account` in the model, and a request spec. Pass `--central` for a resource every tenant shares; it is identical to a plain application’s.

**Terminal · inside your application**

```bash
frappe make resource Note body:string
frappe make resource Tag label:string --central
```

**Expect:** `Note`’s routes sit inside the tenant block, so `frappe routes` lists them as `/:tenant/notes`; `Tag`’s stay central at `/tags`.

## Declare tenanted data {#c-tenancy-schema}

The `tenant` statement adds the `account_id` column and scopes the schema to the bound tenant. The column is never a changeset param. This is the schema `frappe make resource Note body:string` wrote:

**app/models/note.cr · schema excerpt**

```crystal
schema "notes" do
  field id : Int64, primary: true
  tenant account : Account
  field body : String
  timestamps
  json :id, :body, :created_at, :updated_at
end
```

| Condition | Outcome |
| --- | --- |
| A tenanted query with no tenant bound | raises `SugarORM::Tenancy::Missing`: “App::Note is tenanted, but no tenant is bound.” |
| Another tenant’s id | answers 404, like an unknown one |
| A `belongs_to` to a row of another tenant, even from raw SQL | is refused by PostgreSQL’s composite foreign key |
| Creating a tenanted row inside `Caramel::Tenancy.without` | raises |

- Queries, `find`, `count`, `exists?`, `delete_all`, preloads, updates and deletes see only the bound tenant’s rows, and inserts are stamped with it.
- A unique index on a tenanted schema is unique per tenant, so two accounts may hold the same value.
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
a(href: notes_path) { "Notes" }       # /acme/notes
```

With locale prefixes, the tenant comes first: `/acme/fr/notes`. The language switcher keeps the tenant prefix.

## Carry the tenant into background work {#c-tenancy-background}

Outside a request, bind a tenant explicitly. `Caramel::Tenancy.current` and `current?` read the bound one.

**A task or job · account is a loaded App::Account**

```crystal
Caramel::Tenancy.with(account) do
  App::Note.query.count
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
| A cache key or PubSub channel name starting with `t<id>:`, with no tenant bound and outside `Caramel::Tenancy.without` | raises ArgumentError |
| `Caramel::Cache.clear` | clears the bound tenant’s keys; with none bound, the keys with no tenant prefix; inside `without`, every key |

Stage 4 · Operate

## Validate slugs and check membership {#c-tenancy-slugs}

`validate_tenant_slug`, which the generated `Account` changeset calls, checks the address a tenant gets:

| Condition | Outcome |
| --- | --- |
| A slug that is not a lowercase DNS label (letters, digits and hyphens, 1 to 63 characters, no leading or trailing hyphen) | adds `has invalid format` to the field |
| A slug equal to a central route’s first segment, such as `health` or `accounts` | adds `has already been taken` to the field |
| A slug equal to a locale prefix code | adds `has already been taken` to the field |

Tenancy decides which rows a request sees, not who may act in a tenant. Check membership in the application: `ingress authenticate: :member?` on an action names an instance method returning `Bool`, and `false` answers 401 before the contract binds.

[Read the ingress rules →](https://caramelize.dev/docs/0.18.0/security/index.md)

## Add tenancy to existing data {#c-tenancy-existing}

Adding `tenant` to a populated table needs five steps, because the new column is NOT NULL and its index must exist before another tenanted table can reference it.

1. Add `tenant account : Account` to the schema and run `frappe db diff`.

**Terminal · inside your application**

```bash
frappe db diff --name tenant_notes
```

**Expect:** Halts with `NOT NULL column without a default cannot be added to the existing notes table: existing rows have no value for it.` and writes no migration.

1. Write a migration by hand that adds the column as nullable, backfills it and sets it NOT NULL.
2. In a second migration, build the index: `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_notes_on_account_id_and_id" ON "notes" ("account_id", "id")`. When another tenanted table’s key references the table, the differ halts until the index exists and prints this SQL.
3. Run `frappe migrate`, then `frappe db diff` again for the foreign keys.
4. Drain every queue before deploying: a job enqueued without a tenant runs with none.

**Terminal · before the first deploy with tenancy · APP is the application binary**

```bash
APP jobs stats
```

**Expect:** Prints one row per queue with its `running`, `retrying`, `queued`, `scheduled` and `failed` counts. Deploy once every row’s `queued`, `scheduled` and `running` are 0.

| Condition | Outcome |
| --- | --- |
| `frappe db diff` on a populated table that gains a NOT NULL column | halts and writes no migration |
| A job enqueued without a tenant, run on tenanted rows | fails with `SugarORM::Tenancy::Missing` |

[Read the multi-tenancy design ↗](https://github.com/caramelizedev/caramel/blob/v0.18.0/docs/decisions/0025-multi-tenancy.md)

Stage 5 · Limits

## What does not compile {#c-tenancy-refusals}

A router has one tenant block. Each mistake below stops the build.

| Condition | Outcome |
| --- | --- |
| A central route other than `/` that starts with a parameter | fails compilation |
| A tenant route that starts with a central route’s first segment | fails compilation |
| A router with a second tenant block | fails compilation |
| A SweetTalk domain that does not name the tenant, in a program that requires `caramel/tenancy` | fails compilation |

## Not covered yet {#c-tenancy-gaps}

- A tenant is selected by its `/SLUG` path prefix only. There is no host or subdomain tenancy.
- Membership and authorization are the application’s: tenancy answers 404 for another tenant’s rows, and nothing else.
- `Caramel::Tenancy.without` and raw `SugarORM.sql` are unscoped; the application adds the tenant predicate itself.
- Removing tenancy follows the design’s “Plugging out” steps by hand; no command does it.

Prove it

## Test isolation {#c-tenancy-testing}

`tenant_session("acme")` opens a Corretto session in a new account, and the example’s queries see only its rows. `account(db, "globex")` creates a second account to prove isolation. `frappe make resource Note` already wrote these lines into its spec; nothing to add.

**spec/requests/notes_spec.cr · the lines make resource wrote**

```crystal
tenant_session("acme") do |client, db|
  created = client.post("/acme/notes", params: {"body" => "Example <body>"})
  record = App::Note.query.order_by(:id, :desc).first!(db)
  # …
  account(db, "globex")
  client.get("/globex/notes/#{record.id}").should have_status(404)
  # …
end
```

**Terminal · inside your application**

```bash
frappe routes
frappe corretto spec/requests/notes_spec.cr
```

**Passing:** `frappe routes` lists `/:tenant/notes` beside the central `/tags`. `frappe corretto` ends with `Corretto: 1 of 1 workers passed`: a request from `acme` for `globex`’s note answers 404.

[← Internationalization](https://caramelize.dev/docs/0.18.0/internationalization/index.md) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.18.0/testing-html/index.md)

Caramel 0.18.0 · https://caramelize.dev/docs/0.18.0/multi-tenancy/
