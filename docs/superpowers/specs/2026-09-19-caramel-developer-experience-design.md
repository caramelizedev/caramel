# Caramel: developer experience design

Date: 2026-09-19

Status: proposed experience for review. The product direction is agreed; the commands, APIs, and defaults below are design proposals, not implemented features. This is an experience specification, not an implementation plan.

Correction: Crystal is an explicit user requirement. The earlier Ruby foundation was an assistant misinterpretation and is superseded by this revision.

## 1. Product direction

Caramel is an independently designed Crystal web framework and development environment that brings Laravel's attention to the entire developer journey to a compiled, Ruby-like language. Its initial customer is its creator, building real browser-based applications. Community adoption is an ambition; commercial validation is not the first release gate.

The central promise: install Caramel, create an application, and spend your time on the application. Setup, dependencies, conventions, diagnostics, and documentation are part of the product.

Agreed requirements:

- Crystal is the foundation: Ruby-like syntax, static type inference, compile-time checks and macros, fiber-based concurrency, and native compilation are core motivations from the original proposal.
- Efficient execution, low memory use, simple binary distribution, and fast local iteration are design goals. Workload-specific performance and toolchain compatibility must be demonstrated; the original numerical claims are not established results.
- Complete browser applications are the primary experience.
- Frappé is the everyday application CLI, comparable in purpose to Artisan.
- Authentication is optional and added with one command.
- Human clarity comes first. Predictable conventions also help coding agents; there is no separate AI subsystem in this release.
- Caramel owns its public experience while reusing dependable underlying components.

Proposed first-release defaults:

- macOS on Apple Silicon for the managed local installation.
- SQLite locally, with separate development and test databases.
- Server-rendered HTML, ordinary CSS, and browser JavaScript modules.
- Plain Crystal application classes, typed inputs, compiled templates, and readable generated files.
- A native production application binary, with a Linux/musl build path targeting fully static linkage of supported dependencies. A container is a build/distribution option; production must not need a language interpreter. Static linkage and runtime resource requirements are verified on the actual artifact.

These platform and storage defaults limit the first delivery, not the long-term framework.

## 2. The first ten minutes

After installing Caramel through one supported installer:

```sh
frappe new bookshelf
cd bookshelf
frappe dev
```

`new` installs the project's compatible, locked dependency set, prepares its development database, creates local development secrets, and generates a usable styled homepage. It prints the directory it created and the next command. It never overwrites a nonempty destination.

`dev` compiles and boots a development build, opens the browser once, watches application files, and rebuilds/restarts after Crystal source or compiled-template changes. The browser reloads only after a successful build and readiness check. Static CSS and JavaScript edits refresh without recompiling Crystal. It binds to loopback. If the preferred port is occupied, it selects a free port and prints the actual URL. An explicit port request instead produces an actionable conflict error.

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
      application_controller.cr
      books_controller.cr
    models/
      application_record.cr
      book.cr
    inputs/
      book_input.cr
    views/
      layouts/application.html.ecr
      home/index.html.ecr
      books/
        index.html.ecr
        show.html.ecr
        new.html.ecr
        edit.html.ecr
        _form.html.ecr
    assets/
      stylesheets/app.css
      javascript/app.js
  config/
    application.cr
    database.yml
    routes.cr
  db/
    migrations/
    schema.cr
    seeds.cr
  src/
    bookshelf.cr
  spec/
    models/
    requests/
    system/
    spec_helper.cr
  storage/
  public/
  shard.yml
  shard.lock
  .caramel-version
  .env.example
  .env
  .gitignore
  README.md
```

The fresh project has the same conventions but omits the Book-specific files. Databases, local secrets, logs, and caches are ignored by version control. `public/` is the only directory served directly as public files; application source and `storage/` are not exposed.

The README explains how to start, test, migrate, add authentication, and obtain command help. It describes the generated application rather than the framework's internal architecture.

## 5. Crystal that should feel natural

The examples below propose Caramel's application-facing API. They are illustrative excerpts, not existing shard APIs or compile-verified code; the generated resource must include complete actions, routes, and specs. Macros must resolve routes, fields, inputs, and template locals to typed code at compile time.

Routes:

```crystal
# config/routes.cr
Caramel.routes do
  get "/", HomeController, :index
  resources :books, BooksController
end
```

A model with an application-specific rule:

```crystal
# app/models/book.cr
class Book < ApplicationRecord
  table :books

  field id : Int64?, primary: true
  field title : String
  field author : String
  timestamps

  validates :title, presence: true
end
```

Models use reference semantics: `ApplicationRecord` inherits from Caramel's model base class, not a struct. An unsaved record has a nil ID; persisted-record operations must narrow or check that state. The `timestamps` macro supplies the columns used by the example ordering. The model generator emits matching migrations; source typing does not establish that a deployed database matches those declarations.

A typed form input defines writable fields:

```crystal
# app/inputs/book_input.cr
struct BookInput
  include Caramel::FormInput

  field title : String
  field author : String
end
```

A controller excerpt:

```crystal
# app/controllers/books_controller.cr
class BooksController < ApplicationController
  def index : Caramel::Response
    books = Book.order(created_at: :desc).to_a
    render "books/index", books: books
  end

  def create : Caramel::Response
    input = parse_form(BookInput)
    book = Book.new(title: input.title, author: input.author)

    if book.save
      redirect_to books_path, notice: "Book added."
    else
      render "books/new", book: book, status: 422
    end
  end
end
```

The parser reads the `book` form envelope for `BookInput`, rejects undeclared fields, and reports missing/invalid values through the same 422 form-error path while preserving submitted values. Authentication and record authorization remain separate from input typing.

A reusable form excerpt:

```ecr
<form action="<%= action %>" method="post">
  <%= csrf_field %>
  <%= method_field(method) %>
  <%= error_summary(book) %>

  <label for="book_title">Title</label>
  <input id="book_title" name="book[title]" value="<%= book.title %>"
         aria-describedby="book_title_errors">
  <%= field_errors(book, :title, id: "book_title_errors") %>

  <label for="book_author">Author</label>
  <input id="book_author" name="book[author]" value="<%= book.author %>">

  <button type="submit">Save book</button>
</form>
```

Conventions are documented: actions return explicit responses; template names and locals are checked through generated typed render methods; `resources` generates standard CRUD routes and helpers; model tables are pluralized; resource migrations include timestamps. The shared form receives `book`, `action`, and `method` locals; its parent page supplies the appropriate create or update route. Generated input types control writable fields. Application authors add business validations explicitly.

Generated forms provide labels, CSRF protection, accessible error associations, and styled controls. Caramel's template layer must escape ordinary interpolated values, including quoted attribute values, and allow raw markup only through an explicit trusted-HTML type used by framework helpers. ECR-style syntax alone does not supply this security contract. Escaping is an implementation gate. Standard form submission and navigation work without JavaScript. Crystal libraries should supply underlying database and HTTP facilities where they fit; Caramel owns their consistent integration.

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

```crystal
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
| `frappe run FILE` | Compile and run a Crystal script with application context; an interactive console is deferred until its toolchain behavior is proven |
| `frappe build --release` | Produce the native application artifact for the selected supported target |
| `frappe doctor` | Diagnose runtime, dependency, database, and configuration problems without changing them |
| `frappe deps add SOURCE` | Add a shard from an explicit supported source, such as `github:owner/repository`, using Shards and show the resulting dependency changes |
| `frappe deps update [SHARD]` | Explicitly resolve updates and update the lockfile |

Every command supports consistent help, useful exit codes, and plain output when redirected. Project commands are registered at compile time from `app/commands/` into a project-specific executable; Frappé rebuilds that executable when its sources change. Unknown command names show close matches. Secrets are redacted from diagnostics. Machine-readable output can follow when it has a concrete consumer.

Environment defaults to development. Test commands cannot point at the development or production database. Production mutation requires an explicit environment selection and never happens as a side effect of `dev` or `setup`.

## 8. Managed dependencies without a new package manager

Caramel manages one tested Crystal/compiler-library/Shards combination for each framework release. `.caramel-version` selects a versioned Caramel toolchain manifest that pins the exact tool versions and supported platform artifacts. The launcher uses that manifest rather than whatever compiler happens to be on the shell path. It does not replace unrelated global tools or shell configuration.

Shards remains the dependency manager, with standard `shard.yml` and `shard.lock` files. Frappé owns the common workflow and translates failures into useful guidance while retaining the underlying diagnostic. Users can inspect their dependencies and use ordinary Crystal tooling through the managed toolchain. The supported native libraries and linker requirements are included or provisioned by the managed installation; a lockfile alone is not a complete environment.

New projects start from a tested lockfile. Setup restores its exact versions and reports incompatible metadata rather than silently upgrading it. Explicit dependency updates can change the graph and must show that change. A clean-install smoke test must prove the default project requires no manual native-library setup on the supported platform before we advertise this experience.

The installer owns toolchain downloads, integrity verification, and dependency caches. Offline use is supported only when all required artifacts are already cached; an unavailable download produces a resumable failure. Toolchain updates do not overwrite versions still used by existing projects. Cache keys include compiler version, dependency lock, build flags, and target; caches are an optimization, not a guarantee of incremental semantic analysis.

## 9. Architecture boundaries and request flow

Proposed implementation foundations: Crystal's HTTP facilities and fibers; `crystal-db` with a compatible SQLite driver for the first vertical slice; Shards for dependencies; and compiled ECR-style templates behind Caramel's escaping contract. SugarORM remains the intended typed persistence API from the original proposal. Begin with the fields, validations, parameterized queries, migrations, and record lifecycle needed by Bookshelf, evaluating existing Crystal ORM components before choosing reuse or a narrow implementation. Ruby libraries such as Rack, Active Record, Action View, and Bundler are not dependencies.

The implementation plan must prove the selected compiler, libraries, template escaping, and database behavior together before locking exact versions. It must document fiber/parallelism settings and identify blocking calls. Compiler safety applies to instantiated/generated source paths; runtime schema drift, authorization, and external-system failures still need explicit checks.

| Boundary | Responsibility |
| --- | --- |
| Managed installation | Compiler/toolchain selection, native dependencies, artifact integrity, environment isolation, local caches |
| Frappé | Command grammar, generators, feature installation, process supervision, diagnostics |
| Caramel application runtime | Boot, configuration, routes, controller lifecycle, middleware, exception handling |
| SugarORM / persistence integration | Typed model/query API, driver configuration, connection lifecycle, migrations, spec database isolation |
| Browser integration | Escaped rendering, forms, asset delivery, development refresh, shared styles |
| Optional auth feature | Identity, sessions, recovery, integration migrations, views, behavioral tests |

An incoming request passes through host validation, session/CSRF middleware as appropriate, route matching, and the typed controller action. The action reads a declared form input and uses the model layer. A successful mutation redirects; a failed validation re-renders the form with its submitted values and field errors. The compiled renderer returns escaped HTML through Crystal's HTTP response boundary.

Crystal source and compiled-template changes trigger a debounced development rebuild and supervised process replacement, rather than runtime class reloading. A supervisor-owned development endpoint displays a build-error page while a build is broken, so requests do not silently reach stale code. Only a successfully built, ready replacement receives application traffic. The supervisor cleans up its child processes when stopped and does not terminate unrelated services.

The initial development mode uses ordinary compilation with development settings. Interpreter mode (`crystal i`), semantic-only checks, structured diagnostic formats, and compiler-cache improvements require verification on the exact bundled version before becoming supported accelerators. The original document's sub-second interpreter/repair-loop claims do not become guarantees merely by restoring Crystal. No automatic code-repair daemon is included.

## 10. Errors and browser experience

The default interface is restrained and usable: responsive layout, clear typography, visible focus, labeled inputs, and helpful empty/error states. Styling works without a CSS build pipeline. UI visual design is a separate design pass; this document specifies behavior only.

Development errors show the relevant application file, line, explanation, and suggested next action. Internal stack frames remain expandable. Invalid form submissions retain entered data. Missing records return a helpful 404. Production exceptions produce a generic page and a correlation identifier linked to server logs; development traces and secrets stay private.

The local mailbox and development diagnostics bind to loopback and are absent from production. All default state-changing browser forms have CSRF protection, including forms generated before auth is installed.

## 11. Deployment belongs in the journey

The first release provides one documented Linux/musl build recipe and an example deployment of the native binary. Compiled templates and the supported application assets are embedded in the release artifact. Configuration, secrets, persistent data, and any required certificate trust data are supplied explicitly. Database migrations run as an explicit release step using compiled application tooling; production does not need the Crystal compiler or source shards.

Fully static linkage is a target for the supported release dependency set, verified using artifact inspection and execution in a minimal environment. It must not be inferred from a compiler flag. A statically linked application still needs its operating-system services and any documented external resources. Each supported CPU target gets its own built and tested artifact; no universal-binary claim is made.

The initial SQLite deployment is a single application instance with persistent storage and a documented backup/restore procedure. It does not claim horizontal scaling, ephemeral-disk durability, or automatic rollback of schema changes. A later PostgreSQL path must be tested separately.

The deployment smoke test covers a real page, a database write surviving a restart, session behavior, HTTPS-aware cookie settings, and password-reset delivery when auth is installed. A process that merely starts is insufficient evidence.

Roast provisioning, managed cloud hosting, zero-downtime orchestration, and the Latte desktop interface follow demonstrated needs. Managed local installation remains part of the first release even without a desktop interface.

## 12. Acceptance criteria

The Bookshelf application is the reference integration fixture. Its generated files, browser behavior, and documented commands must be exercised together.

- On a clean supported machine without Crystal, Shards, Node, or database services preinstalled, the supported installer and three startup commands open a working website. Download failures are reported distinctly from framework failures.
- Creating the Book resource and migrating yields working browser CRUD. Tests cover valid writes, invalid forms, escaped output, missing records, CSRF rejection, and persisted data after restart.
- `frappe add auth` yields usable registration/login/logout/recovery. Negative tests cover invalid credentials, expired/reused reset tokens, session invalidation, and rate limiting. The documented ownership example prevents cross-user reads and writes.
- A second checkout works through `frappe setup` and `frappe dev`, without manual resolver repair. Development secrets are regenerated locally, never copied from version control.
- Interrupted setup is resumable. Generator and auth-install conflicts preserve user edits. Stopping and restarting development leaves no orphaned processes.
- `frappe test` cannot modify development data. Generated documentation matches command help and actual behavior.
- The deployment smoke test exercises the generated application with persistent storage.
- Compile fixtures reject invalid declared model fields, route/controller bindings, and template-local types on exercised code paths. A broken source edit shows a useful error; correcting it recovers without restarting Frappé manually.
- Release artifact inspection establishes the actual dynamic-library dependencies. The deployed application handles HTTP/database/auth flows without a Crystal compiler, Shards, or application source installed.

Proposed performance targets on a declared reference machine: a new project including its first development compile ready within 30 seconds once dependencies are cached; an already built application booting within 5 seconds; and static CSS/JavaScript edits visible within 1 second at p95 over 20 edits. For Crystal source and compiled-template edits, use an initial p95 target of 3 seconds over representative edits and report actual results before accepting it as a supported promise. Measure cold/warm builds, semantic checks, specs, and release compilation separately on both Bookshelf and a larger fixture. Record hardware, versions, flags, artifact sizes, CPU, and memory; note network conditions for cold installation. The original 20–40 MB RSS and concurrency claims remain workload-specific hypotheses to benchmark.

Qualitative acceptance: the creator uses Caramel for a real application, can explain where each generated file belongs, and can recover from deliberate setup/form errors using the product's own guidance. The Bookshelf demo alone does not establish broader usability.

## 13. Deliberate scope boundaries

The initial experience includes managed setup, a Crystal web application, typed CRUD generation, migrations, compiled templates, basic assets/styles, optional authentication, specs, diagnostics, and a native-binary deployment recipe. Implementation should deliver this in sequential slices; it is not one parallel task per branded product.

We defer the full SugarORM association/eager-loading feature set, a custom package resolver, a new template syntax, a distributed queue engine, a frontend framework, the desktop interface, the hosted control plane, and AI repair/MCP. Typed persistence and safe compiled rendering remain necessary work for the first slice. We also defer supporting every OS and database before the supported combination works well.

The main design risk is making compilation or native dependencies interrupt the otherwise smooth application workflow. Clean-machine setup, measured edit feedback, and the complete browser feature journey are primary acceptance criteria. Crystal is a fixed foundation; if a measured target fails, revise the implementation, supported scope, or explicit performance promise rather than silently switching languages.

## References consulted

- [Laravel installation and framework scope](https://laravel.com/framework/docs/13.x)
- [Artisan](https://laravel.com/framework/docs/13.x/artisan)
- [Laravel starter kits](https://laravel.com/framework/docs/13.x/starter-kits)
- [Crystal dependency management with Shards](https://crystal-lang.org/reference/1.21/man/shards/index.html)
- [Crystal concurrency](https://crystal-lang.org/reference/1.21/guides/concurrency.html)
- [Crystal static linking](https://crystal-lang.org/reference/1.21/guides/static_linking.html)
- [Crystal ECR templates](https://crystal-lang.org/api/1.21.0/ECR.html)

Sources establish available building blocks and inspiration. Caramel-specific behavior, CLI syntax, integration choices, and performance targets above are proposals.
