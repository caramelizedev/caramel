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
- PostgreSQL is the default in development, specs, and production. Local setup should reproduce production database behavior as closely as practical.
- Server-rendered pages include htmx 4 by default.
- Trusted local HTTPS and named project domains are default behavior. Latte's Herd-style environment management is a core product requirement.
- Frappé is the everyday application CLI, comparable in purpose to Artisan.
- Authentication is optional and added with one command.
- Human clarity comes first. Predictable conventions also help coding agents; there is no separate AI subsystem in this release.
- Caramel owns its public experience while reusing dependable underlying components.

Proposed first-release defaults:

- macOS on Apple Silicon for the managed local installation.
- Managed PostgreSQL, with separate project databases and credentials for development and specs; the selected major version is recorded in the project environment manifest.
- Server-rendered HTML, bundled htmx 4, ordinary CSS, and browser JavaScript modules.
- Named HTTPS origins such as `https://bookshelf.caramel.test`. The reserved `.test` suffix is the proposed default; exact `.caramel` is supported as an explicit local override if preferred.
- Latte's shared service manager and a compact macOS menu-bar interface for projects, HTTPS, PostgreSQL, toolchains, logs, and service health.
- Plain Crystal application classes, typed inputs, compiled templates, and readable generated files.
- A native production application binary, with a Linux/musl build path targeting fully static linkage of supported dependencies. A container is a build/distribution option; production must not need a language interpreter. Static linkage and runtime resource requirements are verified on the actual artifact.

These platform and storage defaults limit the first delivery, not the long-term framework.

## 2. The first ten minutes

After installing Caramel through one supported installer, which sets up Latte, the Crystal toolchain, PostgreSQL, local DNS, and the local certificate authority:

```sh
frappe new bookshelf
cd bookshelf
frappe dev
```

`new` installs the project's compatible, locked dependency set, registers its local domain, provisions separate development/spec PostgreSQL databases and credentials, creates local development secrets, and generates a usable styled homepage with htmx 4. It prints the directory it created and the next command. It never overwrites a nonempty destination.

`dev` ensures the project's managed services are healthy, compiles and boots a development build, and opens its named HTTPS URL. Latte routes that stable origin to the project's private loopback upstream. Ports are implementation details and do not appear in the ordinary browser workflow. Crystal source and compiled-template edits trigger rebuild/restart; the browser reloads only after a successful build and readiness check. Static CSS and JavaScript edits refresh without recompiling Crystal.

Illustrative output:

```text
Bookshelf is ready

Website    https://bookshelf.caramel.test
HTTPS      Trusted locally
Database   PostgreSQL · bookshelf_development

Watching your application. Press Ctrl+C to stop.
```

PostgreSQL is installed and managed by Latte; the developer does not need to install a database separately, create roles manually, or run Docker. No application authentication, Redis, or frontend package installation is required to see the homepage. CSS, JavaScript, and htmx use the same development command. Standard startup must not silently fall back to an HTTP/localhost URL if local DNS or trust configuration fails; it explains the exact repair needed.

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
      vendor/htmx-4.0.0.min.js
  config/
    application.cr
    database.yml
    environment.yml
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

The fresh project has the same conventions but omits the Book-specific files. `config/environment.yml` records the PostgreSQL major version, required extensions, and selected local domain suffix without credentials. Latte stores database clusters outside project directories; connection credentials remain local secrets. Local secrets, logs, and caches are ignored by version control. `public/` is the only directory served directly as public files; application source and `storage/` are not exposed.

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

Generated forms provide labels, CSRF protection, accessible error associations, and styled controls. Caramel's template layer must escape ordinary interpolated values, including quoted attribute values, and allow raw markup only through an explicit trusted-HTML type used by framework helpers. ECR-style syntax alone does not supply this security contract. Escaping is an implementation gate. htmx enhances server-rendered interactions by default; standard form submission and navigation also work without JavaScript. Crystal libraries should supply underlying database and HTTP facilities where they fit; Caramel owns their consistent integration.

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
| `frappe open` | Open the project's registered HTTPS URL |
| `frappe sites` | List registered project names, HTTPS URLs, and running/build-error/stopped states |
| `frappe services` | Show managed PostgreSQL, DNS, certificate, and proxy health through Latte |
| `frappe make KIND NAME` | Generate named application files |
| `frappe add auth` | Install the complete authentication feature |
| `frappe migrate` | Apply pending migrations for the explicitly selected environment |
| `frappe seed` | Run the project's explicit seed file; never reset data automatically |
| `frappe test` | Run the application's tests against its separate test database |
| `frappe routes` | List methods, paths, names, and controller actions |
| `frappe run FILE` | Compile and run a Crystal script with application context; an interactive console is deferred until its toolchain behavior is proven |
| `frappe build --release` | Produce the native application artifact for the selected supported target |
| `frappe doctor` | Diagnose runtime, dependency, PostgreSQL, DNS, certificate trust, proxy, and configuration problems without changing them |
| `frappe deps add SOURCE` | Add a shard from an explicit supported source, such as `github:owner/repository`, using Shards and show the resulting dependency changes |
| `frappe deps update [SHARD]` | Explicitly resolve updates and update the lockfile |

Every command supports consistent help, useful exit codes, and plain output when redirected. Project commands are registered at compile time from `app/commands/` into a project-specific executable; Frappé rebuilds that executable when its sources change. Unknown command names show close matches. Secrets are redacted from diagnostics. Machine-readable output can follow when it has a concrete consumer.

Environment defaults to development. Test commands cannot point at the development or production database. Production mutation requires an explicit environment selection and never happens as a side effect of `dev` or `setup`.

## 8. Managed dependencies without a new package manager

Caramel manages one tested Crystal/compiler-library/Shards combination for each framework release. `.caramel-version` selects a versioned Caramel toolchain manifest that pins the exact tool versions and supported platform artifacts. Latte also supplies compatible PostgreSQL and proxy/DNS binaries. The launcher uses that manifest rather than whatever compiler happens to be on the shell path. It does not replace unrelated global tools or shell configuration.

Shards remains the dependency manager, with standard `shard.yml` and `shard.lock` files. Frappé owns the common workflow and translates failures into useful guidance while retaining the underlying diagnostic. Users can inspect their dependencies and use ordinary Crystal tooling through the managed toolchain. The supported native libraries and linker requirements are included or provisioned by the managed installation; a lockfile alone is not a complete environment.

New projects start from a tested lockfile. Setup restores its exact versions and reports incompatible metadata rather than silently upgrading it. Explicit dependency updates can change the graph and must show that change. A clean-install smoke test must prove the default project requires no manual native-library setup on the supported platform before we advertise this experience.

The installer owns toolchain downloads, integrity verification, and dependency caches. Offline use is supported only when all required artifacts are already cached; an unavailable download produces a resumable failure. Toolchain updates do not overwrite versions still used by existing projects. Cache keys include compiler version, dependency lock, build flags, and target; caches are an optimization, not a guarantee of incremental semantic analysis.

### 8.1. PostgreSQL parity and lifecycle

Latte manages isolated, per-user PostgreSQL clusters by major version. Projects on the same major can share a server process, with distinct project/development/spec databases and roles. Application roles are not cluster superusers and cannot access other projects or environments. Migration credentials are separate from ordinary request-serving credentials. Spec parallelism uses distinct databases per worker, and the runner verifies the database identity before any destructive reset.

The project records its PostgreSQL major version, required extensions, UTF-8 encoding, and UTC timezone convention. Development, CI, and the production recipe use the same declared schema, version, and extension expectations. Collation differences across macOS and Linux must be identified and tested; matching the database engine does not promise identical operating systems, network behavior, or production load.

The application uses a bounded connection pool; Latte budgets concurrent project pools against the managed server's capacity. No separate pooler is required for the initial local experience. Readiness, crashes, port conflicts, storage paths, and logs are surfaced through both Latte and Frappé. Services bind privately and database credentials are redacted from diagnostics.

Application-to-PostgreSQL TCP connections use TLS with certificate-chain and hostname verification by default. Latte provisions a stable local database hostname and certificate and provides the CA path to the driver. The exact `crystal-pg` version must demonstrate this verification behavior; libpq documentation is a statement of the desired verification semantics, not proof of a Crystal driver's implementation. Administrative IPC may use a restricted local Unix socket.

Stopping a project does not stop a PostgreSQL server still used by another project. Removing a project never implicitly deletes its data. Major database upgrades are explicit operations with a backup and tested upgrade/restore path, not side effects of updating Caramel. A developer can intentionally point a project at an existing compatible PostgreSQL service.

### 8.2. Latte: named HTTPS projects

Latte is a shared local environment service with a compact menu-bar interface. The first interface lists projects with their URL and state; opens a site, folder, logs, or local mailbox; starts/stops individual projects; and shows PostgreSQL, certificate, DNS, and toolchain health. Frappé and the UI call the same service API and use one ownership registry, rather than running competing supervisors.

A scoped local resolver maps the chosen development suffix to loopback. Caddy routes each exact registered hostname to a private application upstream and terminates HTTPS. The installer handles the macOS resolver configuration and the OS authorization needed for local trust and privileged listeners. Ordinary project commands run without elevation. Existing software on ports 80/443 is diagnosed rather than displaced or silently bypassed with a different browser URL.

The proposed naming default is `<project>.caramel.test`, because `.test` is reserved for testing. Exact `<project>.caramel` can be configured as a local namespace, but `.caramel` is not reserved for this purpose and may conflict with future public DNS. The selection is recorded explicitly; renaming a site updates its route, certificate, and development application origin together. Duplicate names are reported before registration and can be resolved with an explicit alternate name. No suffix or origin changes silently during normal startup.

Each installation has its own local CA. The CA key stays outside repositories with restricted access; leaf certificates renew automatically. The installer establishes trust for the supported browsers and bundled tooling and verifies it with a real HTTPS request. If trust is declined or fails, setup explains the remaining step instead of claiming completion or disabling verification. Local HTTPS uses private certificates, not public ACME certificates. HTTPS is also used for the mailbox and browser-facing development diagnostics; HTTP only redirects to HTTPS.

Caddy is the recommended web TLS issuer/terminator; use one coordinated local trust setup rather than unrelated Caddy and mkcert roots. The implementation spike must also establish how PostgreSQL leaf certificates are issued and renewed under that trust setup. No custom cryptography is introduced.

The UI and app processes remain unprivileged. A narrow helper owns only the necessary resolver/trust/listener changes. The proxy admin interface and Latte control API use restricted local IPC, with registered-project ownership and validated upstreams. Repeated registration reconciles a route instead of appending duplicates. Uninstall removes Caramel-owned resolver/trust entries while preserving data unless deletion is separately requested.

The application trusts forwarded scheme/host headers only from its registered local proxy. Sessions use Secure, HttpOnly, host-only cookies, preferably the `__Host-` prefix; sibling project domains must not share sessions. Origin and CSRF checks use the exact project origin. Private proxy-to-application traffic may use a Unix socket; if it uses TCP, require TLS and verify the upstream certificate. The public development experience remains HTTPS throughout, including refresh connections.

## 9. Architecture boundaries and request flow

Proposed implementation foundations: Crystal's HTTP facilities and fibers; `crystal-db` with `crystal-pg` and managed PostgreSQL; Shards for dependencies; compiled ECR-style templates behind Caramel's escaping contract; locally bundled htmx 4; and Caddy with Latte's resolver/certificate/service management. SugarORM remains the intended typed persistence API from the original proposal. Begin with the fields, validations, parameterized queries, migrations, and record lifecycle needed by Bookshelf, evaluating existing Crystal ORM components before choosing reuse or a narrow implementation. Ruby libraries such as Rack, Active Record, Action View, and Bundler are not dependencies.

The implementation plan must prove the selected compiler, libraries, template escaping, and database behavior together before locking exact versions. It must document fiber/parallelism settings and identify blocking calls. Compiler safety applies to instantiated/generated source paths; runtime schema drift, authorization, and external-system failures still need explicit checks.

| Boundary | Responsibility |
| --- | --- |
| Managed installation | Compiler/toolchain selection, native dependencies, artifact integrity, environment isolation, local caches |
| Latte | Shared service registry, PostgreSQL lifecycle, local DNS/HTTPS/proxy, project supervision, menu-bar controls |
| Frappé | Command grammar, generators, feature installation, Latte integration, diagnostics |
| Caramel application runtime | Boot, configuration, routes, controller lifecycle, middleware, exception handling |
| SugarORM / persistence integration | Typed model/query API, driver configuration, connection lifecycle, migrations, spec database isolation |
| Browser integration | Escaped rendering, htmx 4 full/partial responses, forms, asset delivery, secure development refresh, shared styles |
| Optional auth feature | Identity, sessions, recovery, integration migrations, views, behavioral tests |

An incoming request passes through host validation, session/CSRF middleware as appropriate, route matching, and the typed controller action. The action reads a declared form input and uses the model layer. A successful mutation redirects; a failed validation re-renders the form with its submitted values and field errors. The compiled renderer returns escaped HTML through Crystal's HTTP response boundary.

Crystal source and compiled-template changes trigger a debounced development rebuild and supervised process replacement, rather than runtime class reloading. Latte serves a project-scoped build-error page at the same HTTPS origin while a build is broken, so requests do not silently reach stale code. Only a successfully built, ready replacement receives application traffic. Stopping a terminal-owned project session cleans up that project's processes; shared DNS, proxy, and database services remain available to other projects. UI-launched projects have explicit background ownership visible in both interfaces.

The initial development mode uses ordinary compilation with development settings. Interpreter mode (`crystal i`), semantic-only checks, structured diagnostic formats, and compiler-cache improvements require verification on the exact bundled version before becoming supported accelerators. The original document's sub-second interpreter/repair-loop claims do not become guarantees merely by restoring Crystal. No automatic code-repair daemon is included.

## 10. Errors and browser experience

The default interface is restrained and usable: responsive layout, clear typography, visible focus, labeled inputs, and helpful empty/error states. Styling works without a CSS build pipeline. UI visual design is a separate design pass; this document specifies behavior only.

Development errors show the relevant application file, line, explanation, and suggested next action. Internal stack frames remain expandable. Invalid form submissions retain entered data. Missing records return a helpful 404. Production exceptions produce a generic page and a correlation identifier linked to server logs; development traces and secrets stay private.

The local mailbox and development diagnostics bind to loopback and are absent from production. All default state-changing browser forms have CSRF protection, including forms generated before auth is installed.

### 10.1. htmx 4 by default

The generated layout loads a bundled, pinned htmx 4 distribution from the application's own assets. The initially verified upstream release is 4.0.0 (released 2026-08-28); the implementation locks a tested 4.x patch and its integrity digest. Production and development do not depend on a runtime CDN or npm install. Crystal still renders the HTML; htmx enhances how the browser requests and replaces it.

The generated layout enables boosted same-origin navigation/forms using htmx 4's explicit inheritance, for example `hx-boost:inherited="true"`. Feature templates can request specific fragments. Full page loads, bookmarks, and refreshes return complete documents; partial requests return only the intended region. Header-dependent responses carry the corresponding `Vary` values (including `HX-Request-Type` when used) and authenticated responses use suitable private/no-store policies. htmx headers select presentation only and never establish authorization.

The integration targets the v4 contract rather than copying v2 recipes: inherited attributes are explicit; request/target header formats are handled correctly; and error responses can be swapped. Validation errors retain status 422 and return a usable form/error region. Unexpected errors return a safe, correctly targeted error state. Ordinary successful form submissions use a 303 redirect; enhanced submissions use a verified v4 navigation response such as `HX-Location` on a non-redirect response. The response helper owns this difference so controllers do not duplicate it.

Generated forms retain their native action/method and hidden CSRF field. The layout also provides an escaped inherited CSRF header for enhanced requests; same-origin restrictions prevent sending the token elsewhere. Progressive behavior covers loading feedback, repeat-submit prevention, keyboard focus, accessible error announcements, titles, and browser back/forward. Session expiry, full-page fallback, and JavaScript-disabled forms are tested alongside partial requests.

## 11. Deployment belongs in the journey

The first release provides one documented Linux/musl build recipe and an example deployment of the native binary. Compiled templates and the supported application assets are embedded in the release artifact. Configuration, secrets, persistent data, and any required certificate trust data are supplied explicitly. Database migrations run as an explicit release step using compiled application tooling; production does not need the Crystal compiler or source shards.

Fully static linkage is a target for the supported release dependency set, verified using artifact inspection and execution in a minimal environment. It must not be inferred from a compiler flag. A statically linked application still needs its operating-system services and any documented external resources. Each supported CPU target gets its own built and tested artifact; no universal-binary claim is made.

The production recipe connects the compiled application to PostgreSQL of the declared major version with the declared extensions and migrations. PostgreSQL runs as its own durable service, with documented backup/restore, restricted application credentials, and verified TLS. The application binary does not embed the database server or its data. Production HTTPS uses a real domain and an appropriate trusted certificate; local CA keys and development certificates are never deployed.

The deployment smoke test covers a real page, a database write surviving a restart, session behavior, HTTPS-aware cookie settings, and password-reset delivery when auth is installed. A process that merely starts is insufficient evidence.

Roast provisioning, managed cloud hosting, and zero-downtime orchestration follow demonstrated needs. Latte's managed services, trusted project domains, and core menu-bar interface are in the first-release scope because they deliver the requested development experience.

## 12. Acceptance criteria

The Bookshelf application is the reference integration fixture. Its generated files, browser behavior, and documented commands must be exercised together.

- On a clean supported machine without Crystal, Shards, Node, or database services preinstalled, the supported installer and three startup commands open a working website at its named HTTPS origin with no certificate warning. PostgreSQL is installed and provisioned automatically. Download failures are reported distinctly from framework failures.
- Creating the Book resource and migrating yields working browser CRUD. Tests cover valid writes, invalid forms, escaped output, missing records, CSRF rejection, and persisted data after restart.
- `frappe add auth` yields usable registration/login/logout/recovery. Negative tests cover invalid credentials, expired/reused reset tokens, session invalidation, and rate limiting. The documented ownership example prevents cross-user reads and writes.
- A second checkout works through `frappe setup` and `frappe dev`, without manual resolver repair. Development secrets are regenerated locally, never copied from version control.
- Interrupted setup is resumable. Generator and auth-install conflicts preserve user edits. Stopping and restarting development leaves no orphaned processes.
- `frappe test` cannot modify development data. Generated documentation matches command help and actual behavior.
- The deployment smoke test exercises the generated application with persistent storage.
- Compile fixtures reject invalid declared model fields, route/controller bindings, and template-local types on exercised code paths. A broken source edit shows a useful error; correcting it recovers without restarting Frappé manually.
- Release artifact inspection establishes the actual dynamic-library dependencies. The deployed application handles HTTP/database/auth flows without a Crystal compiler, Shards, or application source installed.
- Two projects run concurrently at distinct HTTPS origins with isolated sessions, roles, development databases, and spec databases. Stopping one leaves the other working. Domain collisions, existing privileged listeners, failed CA trust, certificate renewal, and interrupted registration have tested recovery paths.
- Development, specs, CI, and deployment run against PostgreSQL with the declared version/extensions; no SQLite substitute is used in tests. Pool exhaustion, database restart, wrong-host/untrusted TLS certificates, and accidental cross-environment database selection are tested.
- htmx 4 browser tests cover boosted navigation, partial updates, 422 forms, safe 500 responses, redirects, CSRF, session expiry, back/forward, focus, and JavaScript-disabled fallback. Neither htmx assets nor the default CSS require a CDN or a separate frontend build.
- Latte's core menu-bar actions and Frappé operate on the same project/service state. Service restarts preserve database data, and uninstall removes only owned DNS/trust configuration.

Proposed performance targets on a declared reference machine with Latte's services ready: a new project including database provisioning, HTTPS registration, and its first development compile ready within 30 seconds once dependencies are cached; an already built application booting within 5 seconds; and static CSS/JavaScript edits visible within 1 second at p95 over 20 edits. For Crystal source and compiled-template edits, use an initial p95 target of 3 seconds over representative edits and report actual results before accepting it as a supported promise. Measure cold service startup, installation, database initialization, cold/warm builds, semantic checks, specs, and release compilation separately on both Bookshelf and a larger fixture. Record hardware, versions, flags, artifact sizes, CPU, and memory, including PostgreSQL and Latte overhead; note network conditions for cold installation. The original 20–40 MB RSS and concurrency claims remain workload-specific hypotheses to benchmark.

Qualitative acceptance: the creator uses Caramel for a real application, can explain where each generated file belongs, and can recover from deliberate setup/form errors using the product's own guidance. The Bookshelf demo alone does not establish broader usability.

## 13. Deliberate scope boundaries

The initial experience includes Latte's managed environment and core menu-bar interface, PostgreSQL throughout, trusted named HTTPS project origins, a Crystal web application, typed CRUD generation, migrations, compiled templates, htmx 4, basic assets/styles, optional authentication, specs, diagnostics, and a native-binary deployment recipe. Implementation should deliver this in sequential slices; it is not one parallel task per branded product.

We defer the full SugarORM association/eager-loading feature set, a custom package resolver, a new template syntax, a distributed queue engine, an additional SPA frontend stack, the hosted control plane, and AI repair/MCP. Latte's core project/service interface is required; public tunnels and advanced desktop dashboards can follow later. Typed persistence and safe compiled rendering remain necessary work for the first slice. We also defer supporting every OS and database before the supported combination works well.

The main design risk is making compilation or native dependencies interrupt the otherwise smooth application workflow. Clean-machine setup, measured edit feedback, and the complete browser feature journey are primary acceptance criteria. Crystal is a fixed foundation; if a measured target fails, revise the implementation, supported scope, or explicit performance promise rather than silently switching languages.

## References consulted

- [Laravel installation and framework scope](https://laravel.com/framework/docs/13.x)
- [Artisan](https://laravel.com/framework/docs/13.x/artisan)
- [Laravel starter kits](https://laravel.com/framework/docs/13.x/starter-kits)
- [Crystal dependency management with Shards](https://crystal-lang.org/reference/1.21/man/shards/index.html)
- [Crystal concurrency](https://crystal-lang.org/reference/1.21/guides/concurrency.html)
- [Crystal static linking](https://crystal-lang.org/reference/1.21/guides/static_linking.html)
- [Crystal ECR templates](https://crystal-lang.org/api/1.21.0/ECR.html)
- [htmx 4 release](https://four.htmx.org/announcements/2026-08-28-htmx-4.0.0-is-released)
- [htmx 4 documentation](https://four.htmx.org/docs)
- [htmx 4 changes](https://four.htmx.org/docs/whats-new-in-htmx-4)
- [Laravel Herd project management](https://herd.laravel.com/docs/macos/sites/managing-sites)
- [Caddy local HTTPS and trust](https://caddyserver.com/docs/automatic-https)
- [Caddy administration API](https://caddyserver.com/docs/api)
- [IANA special-use domain registry](https://www.iana.org/assignments/special-use-domain-names)
- [Crystal PostgreSQL driver](https://github.com/will/crystal-pg)
- [PostgreSQL TLS verification semantics](https://www.postgresql.org/docs/current/libpq-ssl.html)
- [PostgreSQL cluster upgrades](https://www.postgresql.org/docs/current/upgrading.html)

Sources establish available building blocks and inspiration. Caramel-specific behavior, CLI syntax, integration choices, and performance targets above are proposals.
