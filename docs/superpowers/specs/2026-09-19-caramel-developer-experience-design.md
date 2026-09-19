# Caramel: developer experience design

Date: 2026-09-19

Status: proposed experience for review. The product direction is agreed; the commands, APIs, and defaults below are design proposals, not implemented features. This is an experience specification, not an implementation plan.

## 1. Product direction

Caramel is an independently designed Ruby web framework and development environment that brings Laravel's attention to the entire developer journey to idiomatic Ruby. Its initial customer is its creator, building real browser-based applications. Community adoption is an ambition; commercial validation is not the first release gate.

The central promise: install Caramel, create an application, and spend your time on the application. Setup, dependencies, conventions, diagnostics, and documentation are part of the product.

Agreed requirements:

- Actual Ruby is the recommended direction, following the user's fondness for Ruby and desire to bring Laravel's lessons to it. Crystal and native-binary performance are no longer requirements.
- Complete browser applications are the primary experience.
- Frappé is the everyday application CLI, comparable in purpose to Artisan.
- Authentication is optional and added with one command.
- Human clarity comes first. Predictable conventions also help coding agents; there is no separate AI subsystem in this release.
- Caramel owns its public experience while reusing dependable underlying components.

Proposed first-release defaults:

- macOS on Apple Silicon for the managed local installation.
- SQLite locally, with separate development and test databases.
- Server-rendered HTML, ordinary CSS, and browser JavaScript modules.
- Plain Ruby application classes and readable generated files.
- A conventional container deployment recipe targeting Linux; no promise of a static executable or zero-downtime provisioning service.

These platform and storage defaults limit the first delivery, not the long-term framework.

## 2. The first ten minutes

After installing Caramel through one supported installer:

```sh
frappe new bookshelf
cd bookshelf
frappe dev
```

`new` installs the project's compatible, locked dependency set, prepares its development database, creates local development secrets, and generates a usable styled homepage. It prints the directory it created and the next command. It never overwrites a nonempty destination.

`dev` boots the application, opens the browser once, watches application files, and reloads the browser after a successful change. It binds to loopback. If the preferred port is occupied, it selects a free port and prints the actual URL. An explicit port request instead produces an actionable conflict error.

Illustrative output:

```text
Bookshelf is ready

Website    http://localhost:3000
Database   storage/development.sqlite3

Watching your application. Press Ctrl+C to stop.
```

No authentication, external database service, Redis, or frontend package installation is required to see the homepage. CSS and JavaScript changes use the same development command.

## 3. Build a complete feature

```sh
frappe make resource Book title:string author:string
frappe migrate
```

The resource generator adds a model, migration, controller, index/show/new/edit pages, a shared form, routes, and behavioral tests. It reports the files it creates and changes, and the URL to visit. The Bookshelf reference feature supports listing, creating, reading, editing, and deleting books.

Generation writes files; migration changes the database. Those are deliberately separate operations. `frappe dev` reports pending migrations with the exact command to run and resumes serving the feature once migrations are applied. It does not silently mutate the schema.

More focused generators share the same grammar:

```sh
frappe make model Book title:string author:string
frappe make controller Books
frappe make migration AddIsbnToBooks isbn:string
frappe make command ImportBooks
```

Focused generators create only their named artifact plus directly required companion files, listed in their help. For example, a model with fields also generates its creation migration and model test. Resource generation is the documented shortest route to working CRUD; it does not build an admin dashboard or infer domain-specific business rules.

Repeating a generator never overwrites edited files. It reports conflicts and leaves existing files unchanged. There is no automatic overwrite flag in the initial release.

## 4. Generated application structure

The following is the application after generating the Book resource:

```text
bookshelf/
  app/
    commands/
    controllers/
      application_controller.rb
      books_controller.rb
    models/
      application_record.rb
      book.rb
    views/
      layouts/application.html.erb
      home/index.html.erb
      books/
        index.html.erb
        show.html.erb
        new.html.erb
        edit.html.erb
        _form.html.erb
    assets/
      stylesheets/app.css
      javascript/app.js
  config/
    application.rb
    database.yml
    routes.rb
  db/
    migrations/
    schema.rb
    seeds.rb
  test/
    models/
    requests/
    system/
    test_helper.rb
  storage/
  public/
  Gemfile
  Gemfile.lock
  .ruby-version
  .env.example
  .env
  .gitignore
  README.md
```

The fresh project has the same conventions but omits the Book-specific files. Databases, local secrets, logs, and caches are ignored by version control. `public/` is the only directory served directly as public files; application source and `storage/` are not exposed.

The README explains how to start, test, migrate, add authentication, and obtain command help. It describes the generated application rather than the framework's internal architecture.

## 5. Ruby that should feel natural

The examples below propose Caramel's application-facing API. They are illustrative excerpts; the generated resource must include complete actions, routes, and tests.

Routes:

```ruby
# config/routes.rb
Caramel.routes do
  root "home#index"
  resources :books
end
```

A model with an application-specific rule:

```ruby
# app/models/book.rb
class Book < ApplicationRecord
  validates :title, presence: true
end
```

A controller excerpt:

```ruby
# app/controllers/books_controller.rb
class BooksController < ApplicationController
  def index
    @books = Book.order(created_at: :desc)
  end

  def create
    @book = Book.new(book_params)

    if @book.save
      redirect_to books_path, notice: "Book added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def book_params
    params.require(:book).permit(:title, :author)
  end
end
```

A reusable form excerpt:

```erb
<%= form_with model: @book do |form| %>
  <%= form.error_summary %>

  <%= form.label :title %>
  <%= form.text_field :title %>
  <%= form.error_for :title %>

  <%= form.label :author %>
  <%= form.text_field :author %>

  <%= form.submit "Save book" %>
<% end %>
```

Conventions are documented: an action with no explicit response renders its matching template; `resources` generates standard CRUD routes and helpers; model tables are pluralized; resource migrations include timestamps. Parameter allowlists control writable fields. Application authors add business validations explicitly.

The form helper produces labels, CSRF protection, accessible error associations, and styled controls. User-provided output is escaped by default. Standard form submission and navigation work without JavaScript. Caramel owns the presentation and helper integration, while established Ruby components should supply underlying rendering and persistence behavior.

This familiar API is intentional. New syntax must solve a demonstrated problem rather than establish visual novelty. The full application workflow is where Caramel must earn its identity.

## 6. Authentication as a complete addition

```sh
frappe add auth
```

On an ordinary local project this single command installs any required locked dependencies, generates the authentication feature, and applies its additive development migrations. It adds registration, login, logout, password reset, session persistence, matching styled pages, and tests.

Feature installation differs from a generator: it completes a named integration, including its declared additive development migrations. Help and output make this distinction explicit. In production the command refuses to apply migrations; deployment uses the normal explicit migration step.

The installer preflights file and route conflicts before changing anything. Rerunning it on an installed feature is a no-op. Interrupted installation can resume using its recorded installation steps; existing user code is preserved and database rollback is never implied by filesystem rollback. A conflict reports the exact files involved and exits without partial edits.

Authentication includes password hashing through a maintained implementation, session rotation on login, session invalidation on logout, expiring single-use reset tokens, CSRF protection, rate limiting, and non-enumerating recovery responses. Local reset emails appear in a loopback-only development mailbox. Production delivery requires explicit mail configuration, checked before deployment.

Existing application routes remain public. Installing authentication does not invent authorization rules or automatically assign ownership to existing records. Controllers opt into login protection:

```ruby
class BooksController < ApplicationController
  require_authentication
end
```

This establishes identity only. The generated documentation shows separate record authorization, including querying through `current_user.books` once the developer has added a user/book association. Tests must cover cross-user access in that example. Social login, teams, billing, and administration are later integrations.

## 7. Frappé's command contract

| Command | Behavior |
| --- | --- |
| `frappe new NAME` | Create a ready-to-run application |
| `frappe setup` | Restore a cloned project, install locked dependencies, and prepare its local database |
| `frappe dev` | Start the local application, browser refresh, and development services it actually uses |
| `frappe make KIND NAME` | Generate named application files |
| `frappe add auth` | Install the complete authentication feature |
| `frappe migrate` | Apply pending migrations for the explicitly selected environment |
| `frappe seed` | Run the project's explicit seed file; never reset data automatically |
| `frappe test` | Run the application's tests against its separate test database |
| `frappe routes` | List methods, paths, names, and controller actions |
| `frappe console` | Open a Ruby console with application context |
| `frappe doctor` | Diagnose runtime, dependency, database, and configuration problems without changing them |
| `frappe deps add GEM` | Add a dependency using the existing Ruby resolver and show the resulting dependency changes |
| `frappe deps update [GEM]` | Explicitly resolve updates and update the lockfile |

Every command supports consistent help, useful exit codes, and plain output when redirected. Project commands are registered explicitly from `app/commands/`; unknown command names show close matches. Secrets are redacted from diagnostics. Machine-readable output can follow when it has a concrete consumer.

Environment defaults to development. Test commands cannot point at the development or production database. Production mutation requires an explicit environment selection and never happens as a side effect of `dev` or `setup`.

## 8. Managed dependencies without a new package manager

Caramel manages one tested Ruby/tooling combination for each framework release. The launcher uses the project's declared Ruby version rather than the user's shell runtime. It does not replace the operating system Ruby or edit unrelated shell configuration.

Bundler and standard gems remain underneath, with a normal Gemfile and lockfile. Frappé owns the common workflow and translates failures into useful guidance while retaining the underlying diagnostic. Users can inspect their dependencies and use ordinary Ruby tooling through the managed runtime.

New projects start from a tested lockfile. Setup restores its exact versions and reports incompatible metadata rather than silently upgrading it. Explicit dependency updates can change the graph and must show that change. A clean-install smoke test must prove the default project requires no manual native-library setup on the supported platform before we advertise this experience.

The installer owns the runtime download, integrity verification, and dependency cache. Offline use is supported only when all required artifacts are already cached; an unavailable download produces a resumable failure. Runtime updates do not overwrite versions still used by existing projects.

## 9. Architecture boundaries and request flow

Proposed implementation foundations: Rack for the HTTP boundary, an existing Rack server, Active Record for relational persistence, Action View for escaped templates and form primitives, and Bundler for dependency resolution. These are library recommendations, not a tested compatibility claim. The implementation plan must first demonstrate them working together without a generated Rails application and lock compatible versions.

| Boundary | Responsibility |
| --- | --- |
| Managed installation | Runtime selection, artifact integrity, environment isolation, local caches |
| Frappé | Command grammar, generators, feature installation, process supervision, diagnostics |
| Caramel application runtime | Boot, configuration, routes, controller lifecycle, middleware, exception handling |
| Persistence integration | ORM configuration, connection lifecycle, migrations, test database isolation |
| Browser integration | Escaped rendering, forms, asset delivery, development refresh, shared styles |
| Optional auth feature | Identity, sessions, recovery, integration migrations, views, behavioral tests |

An incoming request passes through host validation, session/CSRF middleware as appropriate, route matching, and the controller action. The action reads permitted inputs and uses the model layer. A successful mutation redirects; a failed validation re-renders the form with its submitted values and field errors. The renderer returns escaped HTML through the Rack boundary.

Application class reloads occur between requests. A failed reload presents the error rather than silently serving stale application code. Dependency or boot-configuration changes trigger an explicit supervised restart. The development supervisor cleans up its child processes when stopped and does not terminate unrelated services.

## 10. Errors and browser experience

The default interface is restrained and usable: responsive layout, clear typography, visible focus, labeled inputs, and helpful empty/error states. Styling works without a CSS build pipeline. UI visual design is a separate design pass; this document specifies behavior only.

Development errors show the relevant application file, line, explanation, and suggested next action. Internal stack frames remain expandable. Invalid form submissions retain entered data. Missing records return a helpful 404. Production exceptions produce a generic page and a correlation identifier linked to server logs; development traces and secrets stay private.

The local mailbox and development diagnostics bind to loopback and are absent from production. All default state-changing browser forms have CSRF protection, including forms generated before auth is installed.

## 11. Deployment belongs in the journey

The first release provides one documented container recipe and an example deployment, with the Ruby runtime, locked gems, and prepared assets included. Configuration and secrets are supplied externally. Database migrations run as an explicit release step.

The initial SQLite deployment is a single application instance with persistent storage and a documented backup/restore procedure. It does not claim horizontal scaling, ephemeral-disk durability, or automatic rollback of schema changes. A later PostgreSQL path must be tested separately.

The deployment smoke test covers a real page, a database write surviving a restart, session behavior, HTTPS-aware cookie settings, and password-reset delivery when auth is installed. A process that merely starts is insufficient evidence.

Roast provisioning, managed cloud hosting, zero-downtime orchestration, and the Latte desktop interface follow demonstrated needs. Managed local installation remains part of the first release even without a desktop interface.

## 12. Acceptance criteria

The Bookshelf application is the reference integration fixture. Its generated files, browser behavior, and documented commands must be exercised together.

- On a clean supported machine without Ruby, Node, or database services preinstalled, the supported installer and three startup commands open a working website. Download failures are reported distinctly from framework failures.
- Creating the Book resource and migrating yields working browser CRUD. Tests cover valid writes, invalid forms, escaped output, missing records, CSRF rejection, and persisted data after restart.
- `frappe add auth` yields usable registration/login/logout/recovery. Negative tests cover invalid credentials, expired/reused reset tokens, session invalidation, and rate limiting. The documented ownership example prevents cross-user reads and writes.
- A second checkout works through `frappe setup` and `frappe dev`, without manual resolver repair. Development secrets are regenerated locally, never copied from version control.
- Interrupted setup is resumable. Generator and auth-install conflicts preserve user edits. Stopping and restarting development leaves no orphaned processes.
- `frappe test` cannot modify development data. Generated documentation matches command help and actual behavior.
- The deployment smoke test exercises the generated application with persistent storage.

Proposed performance targets, measured after dependencies are cached on a declared reference machine: new project ready within 30 seconds, application boot within 5 seconds, and successful template/CSS edit visible within 1 second at p95 over 20 edits. These are targets, not observed results. Record hardware, artifact sizes, versions, and timings; measure cold installation separately with network conditions noted.

Qualitative acceptance: the creator uses Caramel for a real application, can explain where each generated file belongs, and can recover from deliberate setup/form errors using the product's own guidance. The Bookshelf demo alone does not establish broader usability.

## 13. Deliberate scope boundaries

The initial experience includes managed setup, a Ruby web application, CRUD generation, migrations, basic assets/styles, optional authentication, tests, diagnostics, and one deployment recipe. Implementation should deliver this in sequential slices; it is not one parallel task per branded product.

We defer a custom ORM, package resolver, template language, distributed queue engine, frontend framework, desktop interface, hosted control plane, and AI repair/MCP subsystem. We also defer supporting every OS and database before the supported combination works well.

The main design risk is building a familiar Rails-like API without improving its surrounding experience. The clean-machine setup and complete feature journey are therefore primary acceptance criteria, not finishing touches.

## References consulted

- [Laravel installation and framework scope](https://laravel.com/framework/docs/13.x)
- [Artisan](https://laravel.com/framework/docs/13.x/artisan)
- [Laravel starter kits](https://laravel.com/framework/docs/13.x/starter-kits)
- [Rails getting started](https://guides.rubyonrails.org/getting_started.html)
- [Rack protocol](https://rack.github.io/rack/3.2/SPEC_rdoc.html)
- [Active Record basics](https://guides.rubyonrails.org/active_record_basics.html)
- [Action View overview](https://guides.rubyonrails.org/action_view_overview.html)

Sources establish available building blocks and inspiration. Caramel-specific behavior, CLI syntax, integration choices, and performance targets above are proposals.
