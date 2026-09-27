# PROJECT CARAMEL

### The Agent-Native Hypermedia Monolith

> **Motto:** *Mechanical Sympathy. Poetic Syntax.*

---

## 1. The Caramel Manifesto

1. **The Single Machine is Sufficient.** We reject premature distributed systems. A modern bare-metal server running a compiled LLVM binary backed by PostgreSQL can serve 100 million requests a day on a $40 box.
2. **State Lives in the Database and the Hypermedia.** We eliminate client-side state managers and the JavaScript hydration tax. PostgreSQL holds domain truth; htmx 4 morphs the DOM using server-rendered HTML.
3. **Never Let an Abstraction Hide the Machine.** No Docker overhead in local development. No virtualized filesystem translation penalties. Run natively on the host, communicate over local UNIX domain sockets, and compile to bare-metal machine code.
4. **Data Integrity Over Everything.** Data loss is the only fatal engineering error. Treat database state like Git: branch, test, and verify schema migrations in isolated copy-on-write sandboxes before touching production.
5. **No Tautological Mocks.** A test that asserts against mock expectations verifies nothing about reality. Test subcutaneous black-box behavior against real PostgreSQL database branches and real morphed HTML.
6. **Token-Dense Interfaces Over Complex Daemons.** Reject persistent JSON-RPC/MCP daemons that desync from disk. Give agents fast, stateless POSIX CLI tools emitting compact, token-dense diagnostics rather than bloated JSON wrappers.
7. **Built for Human Joy, Engineered for Machine Reasoning.** Replace opaque runtime reflection with compile-time AST macros. Deliver sub-second auto-repair loops for AI agents and total syntactic clarity for human developers.
8. **Code Must Read Like Poetry.** We reject enterprise plumbing, abstract factory wrappers, and noisy glue code. Programming is an act of literature for humans and deterministic contracts for machines. If an idea is clear in the mind, it must read clearly on the page: stripped of ceremonial bureaucracy, structured with natural cadence, and compressed to pure domain intent.

---

## 2. Architectural Charter & Topology

**Project Caramel** is an open-source, statically typed full-stack web ecosystem authored in **Crystal (`crystallang`)**. It delivers the developer ergonomics of Ruby on Rails and Laravel, the raw execution speed and static safety of C and Rust, the zero-JS client simplicity of htmx 4, the data-layer rigor of Ecto, and the mechanical sympathy of *Backend Lore*.

```
                     [ Client: Browser / Agent CLI ]
                                    │
                                    │ HTTPS / HTTP/3 QUIC (Public Internet)
                                    ▼
                     [ Edge Proxy: Caddy / Cloudflare ]
                                    │
                                    │ Streamlined HTTP/1.1 over UNIX Socket
                                    │ Path: /tmp/caramel_app.sock
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                 CARAMEL HOST PROCESS (SINGLE STATIC BINARY)                 │
│                                                                             │
│  ┌────────────────────────┐                   ┌──────────────────────────┐  │
│  │ HTTP Engine (Radix)    │                   │ Caramel Frappé CLI       │  │
│  │ • RequestContracts     │                   │ • Stateless POSIX Tools  │  │
│  │ • htmx 4 Idiomorph     │                   │ • Tier-1 Type Checker    │  │
│  │ • Caramel Islands      │                   │ • Dual-Mode Diagnostics  │  │
│  │ • SSE Streaming Push   │                   │ • Zero Daemon Desync     │  │
│  └───────────┬────────────┘                   └────────────┬─────────────┘  │
│              │                                             │                │
│              │            CSP Fibers & Channels            │                │
│              ├─────────────────────────────────────────────┤                │
│              │                                             │                │
│  ┌───────────▼────────────┐                   ┌────────────▼─────────────┐  │
│  │ Cold Brew Queue Worker │                   │ Task Scheduler / Cron    │  │
│  │ • FOR UPDATE           │                   │ • In-memory fiber ticks  │  │
│  │   SKIP LOCKED          │                   │ • DB lease acquisition   │  │
│  └───────────┬────────────┘                   └────────────┬─────────────┘  │
│              │                                             │                │
└──────────────┼─────────────────────────────────────────────┼────────────────┘
               │                                             │
               │ UNIX Domain Socket: /tmp/.s.PGSQL.5432      │
               ▼                                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     POSTGRESQL (UNIVERSAL SUBSTRATE)                        │
│                                                                             │
│  • Relational Tables (ACID)            • Queue: caramel_jobs (SKIP LOCKED)  │
│  • PubSub: LISTEN / NOTIFY (SSE bus)   • Cache: caramel_cache (UNLOGGED)    │
│  • Template Snapshots (Branch Engine)  • Full-Text Search: GIN / tsvector   │
└─────────────────────────────────────────────────────────────────────────────┘

```

### The Lineage of Design Decisions

* **From Ruby on Rails:** The **Omakase Monolith** and syntactic elegance. We reject runtime duck-typing and un-traced metaprogramming in favor of compile-time macro ASTs.
* **From Laravel:** Complete **operational cohesion** (queues, schedulers, notifications, mailers, and admin panels in the core ecosystem). We eliminate multi-process sprawl by running web traffic and background workers as cooperative fibers inside a single binary.
* **From Astro & htmx 4:** **Zero-JS client defaults**. We discard Node, npm, Vite, and hydration layers. The server renders semantic HTML; htmx 4's native morphing engine handles flicker-free DOM mutations.
* **From *Backend Lore*:** Radical **mechanical sympathy**. We run directly on bare-metal hardware, connect over local UNIX domain sockets, and enforce migration linters that prevent destructive table locks.
* **From Ecto & Drizzle:** **Separation of Schemas and Changesets**. Models are pure, immutable value structs without hidden lifecycle callbacks. Database mutations are explicit, targeted projections.
* **From Ember.js:** The **URL as a hierarchical state machine** and **automated AST codemods**. Framework migrations are applied via deterministic AST refactoring scripts, ensuring agents never hallucinate deprecated APIs.

---

## 3. The Product Suite

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         PROJECT CARAMEL SUITE                            │
├───────────────────┬──────────────────────────────────────────────────────┤
│ Caramel Core      │ Full-stack web runtime (Macro Router, htmx 4 views)  │
│ SugarORM          │ Pure schemas, explicit changesets, branch-and-diff   │
│ Caramel Cold Brew │ Background queue (SKIP LOCKED) & SSE streaming       │
│ Caramel Latte     │ Bare-metal local runner & database branching engine  │
│ Caramel Frappé    │ Fast, stateless agent CLI suite (POSIX / sub-20ms)   │
│ Caramel Corretto  │ Zero-mock, integration-first verification harness    │
│ Caramel Roast     │ Single-binary static compilation & SSH deployment    │
│ Caramel Prose     │ Poetic ergonomics, semantic units & Slang templates  │
└───────────────────┴──────────────────────────────────────────────────────┘

```

---

# RFC-0001: Caramel Core (Runtime, Routing, & Hypermedia Engine)

**Status:** Approved · Implemented (amended by [ADR 0003](decisions/0003-core-routing-and-contracts.md), [ADR 0004](decisions/0004-htmx4-fragment-negotiation.md) and [ADR 0005](decisions/0005-island-props-helper.md))

**Classification:** Foundational Architecture

**Component:** `caramel-core`

### 1. Context & Problem Statement

Traditional web monoliths couple routing, parameter extraction, and view rendering through dynamic runtime lookups (e.g., Rails `params[:id]`, Laravel `$request->input('id')`). This causes runtime type crashes, dynamic allocation overhead, and silent contract drift between route definitions and controller handlers. On the frontend, client-heavy frameworks force teams into separate build pipelines (Node/Vite) and complex client-side state hydration, while dogmatic hypermedia setups struggle when building complex canvas or drag-and-drop tools.

Caramel Core provides an opinionated, statically compiled full-stack runtime written in Crystal. It eliminates client-side bundlers by pairing an AST macro router with an **htmx 4** hypermedia pipeline, statically verified **RequestContracts**, dual wire-egress capabilities, and an official Web Component island escape hatch (**Caramel Islands**).

### 2. Technical Specification

#### 2.1. Compile-Time Macro Router (`Caramel::Router`)

Routes are declared once in a `Caramel::Router.draw` block. Each declaration is a verb (`get`, `post`, `put`, `patch` or `delete`), a literal path and an Action constant. Dynamic segments are `:snake_case` tokens. Every `field` in an Action's `contract` block records a compile-time constant (`CARAMEL_FIELD_<NAME>`: name, type, nilability, default). The router macro reads those constants to verify each route against its Action ([ADR 0003](decisions/0003-core-routing-and-contracts.md)).

```crystal
# config/routes.cr
module App
  Caramel::Router.draw do
    get "/teams/new", Teams::New
    get "/teams/:team_id", Teams::Show
    patch "/teams/:team_id", Teams::Update
  end
end
```

* **Verification Rules:** Compilation stops with the route's source location and a one-line remediation in each of these cases:
  * The Action is undefined, does not inherit from `Caramel::Action`, or lacks an explicit `contract do ... end` block. An empty block is allowed.
  * A route declares `:team_id` and the contract has no `field team_id`.
  * The bound field is not a non-nilable `String`, `Int32` or `Int64` without a default.
  * A path segment is malformed, a parameter repeats, or the path exceeds 32 segments.
  * Two routes match the same requests, or routes overlap ambiguously (§3).
* **Dispatch Table:** `draw` generates an `AppRouter` class that holds the verified route table, with one generated method per route. At boot the table becomes a segment trie. Static children win over the parameter child, and matching backtracks, so `/teams/new/members` still reaches `/teams/:team_id/members`.
  * Matching walks byte offsets in a stack-allocated `Segments` value. It evaluates no regular expression and allocates nothing.
  * Binding then decodes only the matched parameters, parses the contract and calls the route's method.
  * Unknown paths answer 404. Known paths requested with another verb answer 405 with an `Allow` header. `HEAD` reuses `GET` without a body.
* **Route Listing:** `AppRouter.routes` returns every route with its contract summary, which `frappe routes` prints.

#### 2.2. Request Contracts (`Caramel::RequestContract`)

Input validation is decoupled from the database layer. Route parameters, the query and URL-encoded or multipart bodies bind by name to a typed contract struct. The struct coerces values, checks bounds and aggregates errors. Route matching itself allocates nothing.

```crystal
# app/actions/teams/update.cr
struct Teams::Update < ApplicationAction
  contract do
    field team_id : Int64, min: 1
    field name : String, max: 80
    field seats : Int32, min: 1, default: 5
    field billing_email : String?
    field logo : Caramel::UploadedFile?
  end

  def handle(contract : Contract)
    # contract.team_id : Int64, contract.billing_email : String?
  end
end
```

* **Types:** Fields are `String`, `Int32`, `Int64`, `Float64`, `Bool`, `Time` (RFC 3339 with a zone, normalised to UTC) or `Caramel::UploadedFile`, each optionally nilable.
* **Options:** `min:` and `max:` bound numbers and string lengths. `default:` fills a missing or blank field. An unsupported type or option fails compilation at the declaration.
* **Binding errors:**
  * A name supplied by more than one source is a `Duplicate field` error.
  * A body key that no field declares is an `Unknown field` error. So is an undeclared query key on a write.
  * A missing required field is `is required`.
* **Parsing and failure:** `Contract.parse(input)` returns the contract with every error aggregated. The router calls `handle` only with a valid contract. Otherwise the Action answers 422 through content negotiation (§2.5), as one of:
  * its own HTML form page;
  * `{"errors": …}` for JSON clients;
  * MRDP text for other clients.

  A route parameter that fails conversion or bounds answers 404 instead. `contract.values` keeps the submitted text so a form can re-render it.

#### 2.3. Hypermedia Egress (htmx 4 + Idiomorph)

The default presentation engine targets **htmx 4**, bundled locally with every generated application:

* **Morph Swaps:** `Caramel::Partial` and `Action#morph` default to `innerMorph`. The generated layout inherits `hx-swap="innerMorph"` for boosted navigation. Swaps therefore preserve DOM focus, the caret and scroll position.
* **Multi-Target Ingestion (`hx-partial`):** A single action invocation can target multiple disjoint elements on the page in one round trip. `partials` renders one `<hx-partial>` per target, and htmx 4 swaps each into its own target:

```crystal
partials [
  Caramel::Partial.new("#team-roster", view("teams/_roster", team: team)),
  Caramel::Partial.new("#seat-counter", "<span>14 / 20 Seats Used</span>", swap: "innerHTML"),
]
```

```html
<hx-partial hx-target="#team-roster" hx-swap="innerMorph">
  <div id="member-42" class="member-row">Jane Doe</div>
</hx-partial>
<hx-partial hx-target="#seat-counter" hx-swap="innerHTML">
  <span>14 / 20 Seats Used</span>
</hx-partial>
```

`morph "#team-roster", with: html` is the one-target form. `scripts/check browser` drives Safari through a live application to verify focus and scroll preservation and multi-target ingestion.

#### 2.4. The Island Escape Hatch (`Caramel Islands`)

Rich client-side interactivity can hit an "htmx-only complexity cliff": spreadsheets, canvas tools, drag-and-drop workflow builders. To avoid it, Caramel Core provides official Web Component wrappers. They receive server-rendered props and isolate client-side code without turning the application into an SPA ([ADR 0005](decisions/0005-island-props-helper.md)):

```html
<div class="canvas-container">
  <h2>Workflow Designer</h2>
  <%= island("WorkflowCanvas", {nodes: workflow.nodes, edges: workflow.edges}) %>
</div>
```

```js
// app/assets/javascript/app.js
CaramelIslands.define("WorkflowCanvas", (element, props) => {
  const canvas = drawCanvas(element, props);
  return { update: (next) => canvas.load(next), unmount: () => canvas.destroy() };
});
```

`island` validates the PascalCase name and serializes and escapes `props` exactly once. It emits `<caramel-island component="WorkflowCanvas" props="…" hx-morph-skip-children>`. The element's lifecycle:

* **Mount:** The element mounts once it is both connected and registered, in either order. Until then it is `data-island-state="pending"`.
* **Update:** A morph that changes `props` calls `update(props)` and leaves client-rendered children untouched.
* **Unmount:** Removing the element calls `unmount`.
* **Errors:** Invalid props or a throwing mount set `data-island-state="error"` and dispatch `caramel:island-error`.

#### 2.5. Dual Egress Protocol

Every Action negotiates its egress from inbound headers ([ADR 0004](decisions/0004-htmx4-fragment-negotiation.md)):

1. `HX-Request-Type: partial` $\to$ returns the compiled HTML fragment (the page body with its `<title>`, which htmx extracts) or `<hx-partial>` blocks.
   * htmx 4 sends `HX-Request: true` on every request.
   * It sends `HX-Request-Type: full` when it targets `<body>` or uses `hx-select`, and those requests receive the full document.
   * Redirects answer htmx requests with `HX-Location`.
2. `Accept: application/json` preferred over `text/html` by q-value, on a request without `HX-Request` $\to$ bypasses HTML generation entirely. The value `handle` returned is serialized directly to JSON for native mobile clients or external consumers.
   * An action whose `handle` returns a `Caramel::Response` (`page`, `morph`, `partials`, `redirect_to`, `stream`) has chosen its egress explicitly, so the response passes through unchanged.
3. A client that accepts neither receives contract failures as MRDP text (RFC-0005).

Responses carry `Vary: Accept, HX-Request, HX-Request-Type`.

### 3. Failure Modes & Mitigations

* **Route Collision Overhead:** Deep nesting of dynamic routes can lead to ambiguous path matching.  
  *Mitigation:* The router macro verifies path uniqueness at compile time. It rejects two routes that match the same requests. It also rejects a static route (`/teams/new`) declared after an overlapping dynamic route (`/teams/:id`). Precedence is explicit: declare the static route first, and it wins.
* **Large Request Body Memory Pressure:** Parsing massive multipart payloads in memory can exceed memory limits.  
  *Mitigation:* `Caramel::RequestInput` reads every request before its contract binds ([ADR 0003](decisions/0003-core-routing-and-contracts.md)).
  * It caps URL-encoded bodies and multipart text parts at 2 MiB and answers 413 beyond that.
  * It streams file parts to private request-scoped tempfiles through `HTTP::FormData.parse`, up to 64 MiB in total, and deletes them when the request ends.

---

# RFC-0002: SugarORM (Data Layer, Pure Schemas, & Evolution)

**Status:** Approved · Implemented (amended by [ADR 0007](decisions/0007-sugarorm-schemas-changesets-preload.md) and [ADR 0008](decisions/0008-branch-and-diff-migrations.md))

**Classification:** Core Data Architecture

**Component:** `sugar-orm`

### 1. Context & Problem Statement

Active Record implementations (Rails, Laravel) merge business logic, persistence, and lifecycle hooks into heavy "God Objects." Callbacks (`after_save`, `before_validation`) produce hidden side-effects that make automated code reasoning perilous for AI agents. Conversely, overly academic functional ORMs strip away developer happiness, forcing verbose transaction scripts for basic updates. Furthermore, un-preloaded relationships cause production N+1 query failures, while hand-authored migration files regularly drift out of sync with declared models.

SugarORM is an Ecto- and Drizzle-inspired data layer for Crystal featuring a **Fluent Active Record Facade** over pure immutable schemas, explicit changesets, compile-time association safety, and auto-derived migrations via PostgreSQL catalog diffing.

### 2. Technical Specification

#### 2.1. Pure Schemas & Compile-Time Association Safety

Schemas are immutable structs representing rows in PostgreSQL. They contain zero connection handles and zero hidden lifecycle hooks. Every instance is a stored row. Instances have getters only; `record.with(seats: 6)` returns a changed copy and never persists anything. A relationship's type is decided at compile time by the query that loaded the record ([ADR 0007](decisions/0007-sugarorm-schemas-changesets-preload.md)):

$$\text{Association}(T) = \begin{cases} \text{NotLoaded} & \text{without } \texttt{.preload} \\ \text{Array}(T) & \text{with } \texttt{.preload} \end{cases}$$

```crystal
# app/models/team.cr
struct Team < SugarORM::Schema
  schema "teams" do
    field id : Int64, primary: true
    field name : String
    field seats : Int32 = 5
    field billing_email : String?
    timestamps

    # Typed relation: un-preloaded access fails to compile
    has_many users : User
    belongs_to owner : User?
    index :name, unique: true
  end

  scope larger_than(seats : Int32) { where("seats > ?", seats) }
end

```

`field` accepts `primary:`, a literal default and `renamed_from:`. The other declarations are:

* `timestamps`: adds system-managed `created_at` and `updated_at`.
* `belongs_to`: adds the `<name>_id` column, a foreign key and an index.
* `has_many` and `has_one`: default to the key `<owner>_id`; `foreign_key:` overrides it.
* `index`: declares an index; `unique:` makes it unique.
* `drop_column`: states the intent to remove a column (§2.6).

An unsupported type, a non-literal default or a missing primary key fails compilation at the declaration.

#### 2.2. Idiomatic Association Helpers

`preload(:users)` changes the static type of what the query returns. It resolves through a generated overload per association, so an unknown association is a compile error that lists the valid ones. Each preloaded association costs exactly one extra query:

```crystal
team = Team.query.preload(:users).find!(team_id)
team.users.each do |user|   # Array(User)
  puts user.email
end

Team.query.find!(team_id).users.each { |user| puts user.email }
# Compile error at this line: undefined method 'each' for Team::UsersNotLoaded(…
#   Association 'users' of Team was not preloaded … Remediation: add .preload(:users)
#   to the query that loaded this Team, e.g. Team.query.preload(:users).find(id))

```

Queries are immutable, so each clause returns a new query.

* `where` keywords are generated per schema and typed. A keyword takes a value, `nil`, an `Array` or a `Range`; `where("seats > ?", 3)` is the raw fragment.
* `order_by(:name, :asc)` checks the field name at compile time.
* Scopes, `limit` and `offset` chain like any clause.
* The terminals are `to_a`, `each`, `first`, `first!`, `find`, `find!`, `count`, `exists?` and `delete_all`.

#### 2.3. The Fluent Facade: Ergonomics on Surface, Purity Underneath

Developers can write expressive, single-line updates without instantiating verbose Changeset objects manually. The generated facade builds the schema's explicit changeset and executes it through the Repo:

```crystal
# 1. Developer-Facing Fluent Ergonomics (Rails/Laravel Happiness)
change = team.update(seats: 10, billing_email: "billing@acme.com")
return render_form(change.errors) unless change.saved?

# 2. What the Facade Does Under the Hood:
changeset = Team::UpdateChangeset.new(team, seats: 10, billing_email: "billing@acme.com")
SugarORM::Repo.update(changeset)   # => the same changeset: saved?, record, errors

```

* **Changeset choice:** `Team.create(**)` and `team.update(**)` use `Team::CreateChangeset` and `Team::UpdateChangeset` when the application defines them. Otherwise they use a generated `Team::DefaultChangeset` that permits every non-system field.
* **Keyword checks:** Unknown keywords, and values of the wrong type, fail compilation at the caller.
* **Bang forms:** `create!` and `update!` return the stored record or raise `SugarORM::Invalid`.
* **Explicit handles:** Every facade method and query terminal also accepts an explicit database handle first (`User.create!(db, email: …)`, `Team::Query.where(name: "Acme").first!(db)`), which RFC-0006 uses.
* **Repo:** `SugarORM::Repo.transaction { … }` nests as savepoints. `SugarORM::Repo.bind(connection) { … }` makes one connection the current fiber's for tests and jobs.

#### 2.4. Explicit Mutation Changesets (Advanced Operations)

When complex validations, casting, or conditional checks are required, developers or agents author explicit Changesets. A changeset is the mutable boundary that accumulates errors and its outcome, so it is a class. Schemas stay immutable values:

```crystal
# app/changesets/team.cr
class Team::UpdateChangeset < SugarORM::Changeset(Team)
  param seats : Int32
  param billing_email : String?

  def validate(cs)
    cs.validate_greater_than(:seats, 0)
    cs.validate_format(:billing_email, /^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$/)
  end
end

```

* **Params:** A `param` must name a schema field of a compatible type. Constructor keywords must be declared params. Both are checked at compile time.
* **Validators:** `validate_required`, `validate_presence`, `validate_greater_than`, `validate_less_than`, `validate_length`, `validate_format` and `validate_inclusion`.
* **Unique constraints:** `unique_constraint` maps a PostgreSQL unique violation to a field error.
* **Writes:** Updates write only the changed columns.

#### 2.5. The Branch-and-Diff Migration Engine

Developers and agents never manually write SQL migrations. They modify the `schema` block in Crystal and run `frappe db diff --name NAME`. The engine derives the delta ([ADR 0008](decisions/0008-branch-and-diff-migrations.md)):

1. **Catalog Snapshot:** Latte spawns an ephemeral PostgreSQL branch of the development database behind the RFC-0004 connection guard (`CREATE DATABASE <scratch> TEMPLATE <dev_db> STRATEGY FILE_COPY`). Frappé applies any pending migrations to it.
2. **Schema Introspection:** Frappé queries the branch's `pg_catalog`: tables, columns, defaults, identity, indexes and foreign keys.
3. **AST Comparison:** Frappé builds the application and runs its headless `schema` command, which prints the compiled schema declarations (`SugarORM::Catalog.declared`).
4. **DDL Derivation:** Frappé computes the structural diff and writes an immutable, timestamped migration file, `db/migrations/<UTC timestamp>_<name>.cr`. Online changes go into a separate `…_concurrently.cr` migration.
5. **Verification:** Frappé rebuilds the application, applies the new migrations to the branch and re-diffs to empty. The branch is always dropped, and a failure removes the written files.

`frappe make resource` derives its `CREATE TABLE` migration with the same DDL renderer. After migrating, `frappe migrate` reports any drift between the declarations and the database.

#### 2.6. Production Zero-Lock Migration Linters

The migrator lints every pending migration before executing any statement and enforces three non-negotiable rules:

* **Rule 1 (Concurrent Indexing):** All `ADD INDEX` operations on existing tables must be emitted as `CREATE INDEX CONCURRENTLY`. Standard blocking index DDL fails the lint check.
  * Indexes on a table created in the same migration are exempt, because it has no rows or readers.
  * A migration made only of online statements (`CONCURRENTLY`, `VALIDATE CONSTRAINT`) runs outside a transaction.
  * Mixing online and transactional statements is rejected.
  * The migrator never journals an index that PostgreSQL left `INVALID`.
* **Rule 2 (Non-Null Additions):** Adding a `NOT NULL` column without a default value to an existing table is rejected by the linter, preventing table rewrites on populated tables.
* **Rule 3 (Rename Safety):** Renaming a field requires an explicit `renamed_from: :old_col` AST directive. Removing one requires `drop_column :old_col`. Derived SQL carries a `-- caramel:allow-rename` or `-- caramel:allow-drop` annotation. Without an explicit origin, the diff engine refuses to emit a destructive `DROP COLUMN` and halts with a diagnostic and a `Remediation:` line.

### 3. Failure Modes & Mitigations

* **Complex SQL Beyond Basic ORM Scope:** Analytical queries requiring window functions, CTEs, or complex aggregations can tempt developers to drop into raw, untyped strings.  
  *Mitigation:* SugarORM exposes a type-checked `SugarORM.sql` block supporting CTEs, Window Functions, and `RETURNING` clauses with statically typed `NamedTuple` results. The declared shape is checked against the result's columns, and a mismatch raises `SugarORM::ShapeError`:

```crystal
ranked = SugarORM.sql(<<-SQL, 30.days.ago, as: {team_id: Int64, total: Int64, rank: Int32})
  WITH totals AS (SELECT team_id, count(*) AS total FROM users WHERE created_at > $1 GROUP BY team_id)
  SELECT team_id, total, rank() OVER (ORDER BY total DESC)::int4 AS rank FROM totals
  SQL
```

* **Prototyping Friction from Strict Linters:** Zero-lock migration linters (e.g., forcing `CONCURRENTLY`) can slow down early exploratory prototyping on empty local databases.  
  *Mitigation:* `frappe db diff --dev-override` and `frappe migrate --dev-override` turn violations and overridable halts into warnings only when `CARAMEL_ENV=development`. The test and production environments, which include staging, always enforce the rules.

---

# RFC-0003: Caramel Cold Brew (Concurrency, Queues, & Real-Time PubSub)

**Status:** Approved · Implemented (amended by [ADR 0009](decisions/0009-cold-brew-queue-pubsub-cache.md))

**Classification:** Concurrency & Real-Time Engine

**Component:** `caramel-cold-brew`

### 1. Context & Problem Statement

Traditional architectures rely on external dependencies (Redis, RabbitMQ, Memcached, Sidekiq) to manage asynchronous workloads, caching, and real-time messaging. This introduces distributed system failure modes, network hop latency, operational cost, and the **dual-write problem**—where database writes succeed but message queue pushes fail.

Caramel Cold Brew collapses this entire infrastructure footprint into PostgreSQL and Crystal’s fiber-based CSP concurrency model.

### 2. Technical Specification

#### 2.1. The Atomic Queue Substrate (`SKIP LOCKED`)

All background jobs are written to the `caramel_jobs` table inside the *same database transaction* as application business logic. `T.enqueue` writes through `SugarORM::Repo`'s current connection, so inside `SugarORM::Repo.transaction` a job commits or rolls back with the business write. The table is a framework migration (`Caramel::ColdBrew::MIGRATIONS`) that every generated application applies first ([ADR 0009](decisions/0009-cold-brew-queue-pubsub-cache.md)):

```sql
CREATE TABLE caramel_jobs (
  id BIGINT GENERATED ALWAYS AS IDENTITY,
  queue TEXT NOT NULL DEFAULT 'default',
  class_name TEXT NOT NULL,
  payload JSONB NOT NULL,
  priority INT NOT NULL DEFAULT 0,
  attempts INT NOT NULL DEFAULT 0,
  run_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  locked_at TIMESTAMPTZ,
  locked_by TEXT,
  failed_at TIMESTAMPTZ,
  last_error TEXT,
  enqueued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ,
  PRIMARY KEY (id, enqueued_at)
) PARTITION BY RANGE (enqueued_at);

CREATE INDEX caramel_jobs_fetch
ON caramel_jobs (queue, run_at, priority DESC)
WHERE locked_at IS NULL AND failed_at IS NULL AND finished_at IS NULL;

```

Jobs are typed values with retry policies (RFC-0008 §2.3):

```crystal
# app/jobs/send_invitation.cr
struct SendInvitation < Caramel::ColdBrew::Job
  queue "mailers"
  retry_on Stripe::RateLimitError, attempts: 5, backoff: :exponential, base: 2.seconds
  param invite_id : Int64

  def perform
    # …
  end
end

SugarORM::Repo.transaction do
  invite = Invite.create!(email: "elena@acme.com")
  SendInvitation.enqueue(invite_id: invite.id)   # same transaction: no dual write
end
```

* **Enqueue:** `enqueue` takes `run_at:` and `priority:`. Unknown keywords are compile errors.
* **Retry rules:** `Caramel::ColdBrew::Job.retry_on` adds global rules. A job's own rules win, then its parents', then the global rules, then the default of 3 exponential attempts from 1 s.

#### 2.2. Worker Fiber Loop

Cold Brew spawns a configurable pool of green execution fibers within the single host binary. The generated application's `serve` starts it, unless `CARAMEL_ENV=test`, with `Caramel::ColdBrew.start(database_url)`. The queues and per-queue concurrency come from `CARAMEL_WORKER_QUEUES` and `CARAMEL_WORKER_CONCURRENCY`. It uses its own connection pool and stops gracefully on SIGTERM:

```crystal
# src/caramel/cold_brew/worker.cr (simplified)
module Caramel::ColdBrew
  class Worker
    def initialize(@queue = "default", @concurrency = 16)
    end

    def start
      @concurrency.times do
        spawn do
          until @stopping
            if job = claim(@queue)            # the query below, on this fiber's bound connection
              run(job)                        # perform + finished_at = now() in one transaction;
            else                              # a failure reschedules with backoff or sets failed_at
              sleep 50.milliseconds
            end
          end
        end
      end
    end
  end
end

```

```sql
WITH selected AS (
  SELECT id, enqueued_at FROM caramel_jobs
  WHERE queue = $1 AND run_at <= NOW() AND locked_at IS NULL AND failed_at IS NULL AND finished_at IS NULL
  ORDER BY priority DESC, id ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED
)
UPDATE caramel_jobs AS jobs
SET locked_at = NOW(), locked_by = pg_backend_pid()::text, attempts = attempts + 1
FROM selected
WHERE jobs.id = selected.id AND jobs.enqueued_at = selected.enqueued_at
RETURNING jobs.id, jobs.class_name, jobs.payload, jobs.attempts;
```

* **Scheduler:** `Caramel::ColdBrew.every(1.hour, "nightly-cleanup") { CleanupJob.enqueue }` is the charter's in-process scheduler. Each tick takes a database lease (`pg_try_advisory_xact_lock` plus a `caramel_schedules` row), so exactly one process runs each period.
* **Maintenance fiber:** It releases stale locks whose backend is gone.

#### 2.3. Real-Time PubSub via SSE

Cold Brew eliminates WebSockets for hypermedia updates. It dedicates one listener connection per process to PostgreSQL's `LISTEN / NOTIFY` stream. That connection reconnects with backoff and re-`LISTEN`s. The broker bridges database events directly into Server-Sent Events (SSE) connections running over HTTP/1.1 or HTTP/2.

* **Publish:** `Caramel::ColdBrew.publish(channel, payload)` runs `pg_notify` on the current Repo connection, so it is delivered only if its transaction commits.
* **Delivery:** Each subscriber has an ordered mailbox, and delivery never blocks the broker.
* **Lifetime:** A subscription ends when its owning fiber dies, so the action below does not leak. `subscribe(channel) { |events| … }` unsubscribes explicitly.
* **Framing:** `Caramel::SSE.write(io, data, event: "BoardUpdated")` frames multi-line data.

```crystal
struct Boards::Live < Caramel::Action
  contract do
    field board_id : Int64
  end

  def handle(contract : Contract)
    channel = Channel(String).new
    Caramel::ColdBrew.subscribe("board_#{contract.board_id}", channel)

    stream "text/event-stream" do |io|
      loop do
        io << "event: BoardUpdated\ndata: " << channel.receive << "\n\n"
        io.flush
      end
    end
  end
end

```

#### 2.4. Cache Subsystem via `UNLOGGED` Tables

The `Caramel::Cache` facade wraps an `UNLOGGED` PostgreSQL table (`caramel_cache`) that bypasses WAL writes entirely. Reads and writes go over UNIX domain sockets on the current Repo connection:

* **API:** `write(key, value, expires_in:)`, `read`, `fetch(key, expires_in:) { … }`, `delete` and `clear`.
* **Expiry:** TTL expirations are handled by the automatic background maintenance fiber, which vacuums expired rows every 60 s. Expired entries read as `nil` before that.

### 3. Failure Modes & Mitigations

* **PostgreSQL WAL Bloat Under High Job Volume:** Rapidly inserting, updating, and deleting hundreds of thousands of jobs can saturate write-ahead logs and lead to table bloat.  
  *Mitigation:* Cold Brew uses time-partitioned tables (`caramel_jobs_pYYYY_MM_DD`). Finished jobs are marked, not deleted. Once every row in a partition past the retention window (7 days by default) is finished or failed, the maintenance fiber drops the whole partition, so completed jobs never need individual row `DELETE` queries and VACUUM is not saturated.
  * Partition DDL runs through two `SECURITY DEFINER` functions owned by the migration role. The least-privileged runtime role can therefore create tomorrow's partitions and drop old ones.

---

# RFC-0004: Caramel Latte (Bare-Metal Local DX & Database Branching)

**Status:** Approved

**Classification:** Local Developer Experience & Substrate

**Component:** `caramel-latte`

### 1. Context & Problem Statement

Docker for local development incurs massive resource penalties: VirtioFS disk translation drag, high idle RAM usage (3–5 GB), and slow file-watcher events on macOS. Conversely, running databases locally without virtualization historically risked environment contamination and made testing concurrent operations messy. Furthermore, template-based database cloning fails catastrophically if active pool connections remain open during the clone command.

Caramel Latte establishes a zero-Docker, bare-metal local development environment. It leverages the host OS kernel and native PostgreSQL capabilities to deliver instant file-watching, **sub-100ms database branching**, and connection-guarded isolation.

### 2. Technical Specification

#### 2.1. Zero-Docker Native Process Supervision

Latte manages the application lifecycle using direct POSIX host process signals:

* **UNIX Domain Socket Binding:** All internal communication (App to Postgres) bypasses the TCP network loopback, writing directly to `/tmp/.s.PGSQL.5432`.
* **Kernel File Watching:** Latte watches source directories using `kqueue` (macOS) or `inotify` (Linux). Changes trigger an instant semantic AST rebuild (`crystal build --no-codegen`), providing compilation feedback in under 200ms.

#### 2.2. Connection-Guarded Database Branching Substrate

Latte treats PostgreSQL databases like ephemeral Git branches, wrapping clone commands in strict connection guards:

```bash
caramel latte branch create feat-stripe-webhooks

```

* **Execution Sequence:**
1. Latte acquires an administrative pool connection to the root `postgres` catalog.
2. Disconnect guard executed:
```sql
ALTER DATABASE caramel_dev WITH ALLOW_CONNECTIONS false;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity 
WHERE datname = 'caramel_dev' AND pid <> pg_backend_pid();

```


3. Template clone command executed:
```sql
CREATE DATABASE caramel_feat_stripe_webhooks TEMPLATE caramel_dev;
ALTER DATABASE caramel_dev WITH ALLOW_CONNECTIONS true;

```


4. The clone operation completes via disk block pointers (APFS/ZFS reflink or Postgres page cloning) in **50ms – 100ms**.



### 3. Failure Modes & Mitigations

* **Postgres Access Lockups During Hard Crashes:** If the development supervisor crashes while connections to the template database are disabled, developers can get locked out.  
  *Mitigation:* Latte registers host process signal traps (`SIGINT`, `SIGTERM`) to restore `ALLOW_CONNECTIONS true` on primary catalogs, and verifies connectivity on every supervisor reboot.

---

# RFC-0005: Caramel Frappé (Stateless Agent CLI & Dual-Mode Diagnostics)

**Status:** Approved

**Classification:** Autonomous Agent Tooling & Interface

**Component:** `caramel-frappe`

### 1. Context & Problem Statement

Persistent background daemons like the Model Context Protocol (MCP) suffer from state drift, protocol framing overhead (JSON-RPC 2.0), and silent daemon crashes. Furthermore, verbose JSON diagnostic formats consume precious LLM attention windows, burning context on punctuation and brackets instead of semantic code logic. Conversely, human developers struggle to read raw, unformatted token streams in their terminals.

Caramel Frappé discards long-running daemons in favor of **stateless, sub-20ms POSIX CLI commands** and **Dual-Mode Diagnostics** (rich ANSI visualization for humans; compact, token-dense text for AI agents).

### 2. Technical Specification

#### 2.1. Stateless POSIX Tooling Surface

Frappé provides an invariant discovery manifest via `caramel agent-manifest`:

```text
CARAMEL CLI INTERFACE (STRICT TOKENS)
caramel check                   # Runs Tier-1 AST type check (--no-codegen). Emits MRDP.
caramel routes [filter]         # Dumps matched route contracts and parameter schemas.
caramel db:branch [name]        # Forks isolated Postgres template DB (outputs URI).
caramel db:diff --name [name]   # Diffs model AST against catalog; auto-generates safe DDL.
caramel corretto [path]         # Runs integration probe with synchronous queue drain.

```

#### 2.2. Two-Tier Compilation Pipeline

1. **Tier 1 (Verification Loop):** Invoked via `caramel check`. Runs `crystal build --no-codegen`. Performs syntax parsing, macro evaluation, and whole-program type inference in **~180ms**. Machine code generation is skipped.
2. **Tier 2 (Artifact Generation):** Full native LLVM machine code compilation and linking is deferred exclusively to deployment (`caramel roast`) or staging gates.

#### 2.3. Dual-Mode Diagnostic Formatting

* **Mode A: Human Interactive (TTY Output):** Outputs full-color ANSI formatting, showing exact line extracts, arrows pointing to syntax violations, and formatted Markdown remediation advice.
* **Mode B: Agent Execution (`--agent` or Non-TTY Piped Stream):** Strips all ANSI codes and formatting boilerplate, outputting a **Dense Diagnostic Text (MRDP)** payload that saves over 70% in LLM token consumption:

```text
ERR CONTRACT_MISMATCH:422 at src/app/actions/teams/create.cr:14:5
NODE: RequestContract
MISSING: tenant_id:String
PATCH: INSERT "field tenant_id : String" AT 14:5

```

### 3. Failure Modes & Mitigations

* **Agent Hallucinating Obsolete CLI Flags:** LLM coding agents often hallucinate flags learned from other frameworks.  
  *Mitigation:* Frappé strictly validates CLI inputs. Any unrecognized argument terminates immediately with exit code `1` and outputs the exact single-line syntax for the intended command.

---

# RFC-0006: Caramel Corretto (Zero-Mock Integration Testing)

**Status:** Approved · Implemented (amended by [ADR 0010](decisions/0010-corretto-harness.md))

**Classification:** Quality Assurance & Verification

**Component:** `caramel-corretto`

### 1. Context & Problem Statement

Mock-driven unit tests provide a false sense of security. They test whether internal stubs were called with expected strings rather than verifying real production behavior. Full-stack browser automation (Playwright, Selenium) is brittle and slow, while naive database integration testing causes massive test-suite slowdowns. Furthermore, background queue execution in tests often results in race conditions that force developers into flaky `sleep()` loops.

Caramel Corretto enforces an **integration-first, zero-mock testing harness** that verifies application behavior subcutaneously against real PostgreSQL branches, synchronous queue drains, and real morphed HTML with sub-millisecond per-test isolation.

### 2. Technical Specification

#### 2.1. The Subcutaneous Testing Boundary

Corretto asserts exclusively against **observable ingress, database state, and hypermedia egress**. Mocking internal Crystal classes or methods is strictly forbidden, and this is enforced in two places:

* Loading a mocking library is a compile error.
* `frappe corretto` refuses spec files that call mocking APIs, naming the file and line.

Generated applications `require "caramel/corretto"` in `spec/spec_helper.cr` ([ADR 0010](decisions/0010-corretto-harness.md)).

```crystal
# spec/actions/teams/create_spec.cr
require "../../spec_helper"

describe Teams::Create do
  it "creates team, sets owner, and synchronously processes notification" do
    Corretto.session do |client, db|
      user = User.create!(db, email: "founder@caramel.dev")
      client.sign_in(user)

      # 1. Ingress: Authentic htmx request
      response = client.post("/teams", 
        headers: { "HX-Request" => "true" },
        params: { "name" => "Acme Corp", "seats" => "10" }
      )

      # 2. Hypermedia Egress Verification
      response.should have_status(200)
      response.should render_partial("#team-list", swap: "innerMorph")
      response.body.should contain("Acme Corp")

      # 3. Real State Verification
      team = Team::Query.where(name: "Acme Corp").first!(db)
      team.seats.should eq(10)
      team.owner_id.should eq(user.id)

      # 4. Synchronous Queue Drain
      Caramel::ColdBrew.drain_queue!(db, "default")
      Notification::Query.where(user_id: user.id).count(db).should eq(1)
    end
  end
end

```

* **The client** drives `Caramel::Application#handle` in-process on the example's own connection. It keeps a cookie jar, attaches CSRF, `Origin` and `Host` automatically, and offers `get`, `post`, `put`, `patch`, `delete` and `follow_redirect`.
* **`sign_in(user)`** writes `user_id` into the signed `Caramel::Session` cookie. Actions read it through `session`.
* **Matchers:** `have_status`, `render_partial(target, swap:)`, `redirect_to`, `have_header`, `render_page` and `have_row(Schema, **conditions)`.

#### 2.2. Three-Tier Isolation Lifecycle

1. **Tier 1 (Worker Suite Boot):** `frappe corretto` migrates the spec database once. It then spins up one isolated database per parallel test worker through Latte, cloned behind the connection guard (`CREATE DATABASE caramel_spec_<site>_w1 TEMPLATE caramel_spec_<site>`). Each worker is a separately compiled spec binary with its own database URL.
2. **Tier 2 (Per-Test Savepoints):** Every `it` block runs inside a PostgreSQL `SAVEPOINT` on the worker's single connection, which is bound to the example's fiber with `SugarORM::Repo.bind`. The example's in-process requests and drained jobs share that transaction. Upon test completion, `ROLLBACK TO SAVEPOINT` undoes everything, eliminating catalog cloning overhead between individual tests.
3. **Tier 3 (Catalog Reset):** Corretto fingerprints the public catalog at boot and checks it after every example. The worker database is torn down and recreated from the migrated template only if un-rollbackable DDL changed the catalog. Corretto names the example that did it. Examples tagged `catalog` run outside the savepoint, on a migration-role connection, and always reset.

#### 2.3. Synchronous Queue Drain Mode

In an integration test, background asynchronous polling is a liability. Corretto forces Cold Brew into **Synchronous Queue Drain Mode**:

* Fibers do not poll in the background during tests: `serve` starts no workers under `CARAMEL_ENV=test`.
* The test harness explicitly executes all enqueued jobs on demand via `Caramel::ColdBrew.drain_queue!(db, "queue_name")`.
  * The drain repeats until the queue is empty, including jobs that jobs enqueue.
  * It raises `Caramel::ColdBrew::DrainFailure`, listing every failed job.
  * Jobs scheduled in the future are skipped unless `include_scheduled: true` is passed.
* Tests never write `sleep()` statements.

#### 2.4. Wire-Level External Fakes

External third parties (Stripe, Twilio, AWS) are never mocked by monkey-patching language methods.

Applications call them through `Caramel::Outbound`. It connects directly in production. In specs it sends real absolute-form HTTP/1.1 requests to a lightweight local socket-level proxy started by Corretto, which matches them by method and URL and returns static, recorded responses from `spec/fixtures/wire/`:

```crystal
Corretto.stub_wire("https://api.stripe.com/v1/customers")
  .to_return(status: 200, fixture: "stripe/customer_created.json")

```

* **Unmatched requests:** They receive `502 Unstubbed outbound request: METHOD URL`, so no spec can reach the network.
* **Recording:** `Corretto.wire_requests` records what was sent.
* **Reset:** Stubs reset after each example.

### 3. Failure Modes & Mitigations

* **Test Suite Execution Creep:** As integration suites grow to thousands of tests, savepoint rollbacks and database queries accumulate run time.  
  *Mitigation:* Corretto supports multi-core parallel worker splits (`frappe corretto --concurrency=8`, 1 to 8 workers).
  * Each worker is paired with an independent Latte database cloned from the migrated spec template.
  * Spec files are split round-robin, and output is prefixed per worker. The exit status fails if any worker fails.
* **Flaky Asynchronous Assertions:** Background jobs executing on polling loops cause timing races and force flaky `sleep()` calls.  
  *Mitigation:* Queues run in **Synchronous Drain Mode** during tests. Background polling is disabled, and jobs are executed deterministically on demand via `Caramel::ColdBrew.drain_queue!`.

---

# RFC-0007: Caramel Roast & Ecosystem Operations (Deployment, SDKs, & Sustainability)

**Status:** Approved

**Classification:** Packaging, Release, Production Operations, & Ecosystem

**Component:** `caramel-roast`

### 1. Context & Problem Statement

Deploying modern web applications often involves heavy operational complexity: multi-stage Docker container builds, container orchestrators (Kubernetes), complex ingress networking, and bloated server images. Furthermore, niche language ecosystems frequently stall due to an "ecosystem desert"—where missing third-party SDKs (Stripe, S3, Twilio) prevent production adoption—and lack a commercial flywheel to fund full-time maintainers.

Caramel Roast adheres to the *Backend Lore* single-binary deployment philosophy, establishes the **First-Party Five** core SDK suite, and funds development through an open-core commercial ecosystem.

### 2. Technical Specification

#### 2.1. Static Asset Inlining & Static Binary Compilation

Roast bakes all static assets (compiled CSS, htmx 4 scripts, static SVGs) directly into the read-only data segment of the compiled binary using Crystal’s macros, producing a zero-dependency static executable linked against `musl`:

```bash
crystal build src/app/server.cr \
  --static \
  --release \
  --no-debug \
  -Dpreview_mt \
  -o bin/caramel_app

```

#### 2.2. Zero-Downtime Atomic Socket Handover

Roast deploys directly over standard SSH:

1. Uploads the new binary to `/opt/caramel/releases/[timestamp]`.
2. Runs pending SugarORM migrations against the live database using zero-lock verification.
3. Starts the new binary, binding to the shared UNIX domain socket `/run/caramel/app.sock` via `SO_REUSEPORT`.
4. Sends `SIGTERM` to the old process once the new binary passes internal health checks.

#### 2.3. The "First-Party Five" Strategy

To eliminate the Crystal ecosystem desert, Caramel Core commits to maintaining five official, zero-dependency first-party shards:

| Shard | Subsystem Functionality |
| --- | --- |
| **`Caramel::Billing`** | Native Stripe API client, card charging, subscription webhooks. |
| **`Caramel::Storage`** | Direct S3, Cloudflare R2, and local disk blob streaming. |
| **`Caramel::Mail`** | Transactional delivery via Postmark, Resend, and standard SMTP. |
| **`Caramel::Auth`** | OAuth2 providers, Passkeys/WebAuthn, and session guards. |
| **`Caramel::Notify`** | Transactional SMS via Twilio and web push notifications. |

*Where complex third-party C libraries exist, Caramel binds directly to raw C headers (`lib C`) with zero FFI overhead.*

#### 2.4. The Commercial Flywheel

Caramel’s ongoing development is sustainably funded via a two-tier product model inspired by Laravel:

```
┌─────────────────────────────────────────────────────────────┐
│                 THE CARAMEL COMMERCIAL FLYWHEEL             │
├─────────────────────────────────────────────────────────────┤
│ OPEN-SOURCE FOUNDATION                                      │
│ • Caramel Core, SugarORM, Cold Brew, Latte, Frappé, Corretto│
├─────────────────────────────────────────────────────────────┤
│ COMMERCIAL DEVELOPER PRODUCTS                               │
│ • Caramel Barista: First-party, schema-driven Admin Panel   │
│   (Analogous to Laravel Nova / Filament)                    │
│ • Caramel SaaS Kit: Production starter kit with teams,      │
│   billing, RBAC, and audit logs                             │
├─────────────────────────────────────────────────────────────┤
│ CLOUD INFRASTRUCTURE (ROAST CLOUD)                          │
│ • Single-click deployment of Caramel static binaries to VPS │
│ • Managed host orchestration with automated Postgres        │
│   template branching for staging and preview environments   │
└─────────────────────────────────────────────────────────────┘

```

### 3. Failure Modes & Mitigations

* **Failed Migration Halting Cutover:** If an applied migration introduces a breaking schema change before traffic cuts over, the application can enter a split-brain state.  
  *Mitigation:* Roast creates an atomic pre-deployment PostgreSQL restore point and executes DDL in an isolated transaction. If the new binary fails its post-boot health check within 10 seconds, Roast triggers an automated rollback to the previous binary and rolls back the migration.

---

# RFC-0008: Poetic Ergonomics, Conceptual Compression, & Semantic Syntax

**Status:** Approved

**Classification:** Developer Experience, Aesthetics, & Language Design

**Component:** `caramel-core` / `sugar-orm` / `caramel-corretto`

### 1. Context & Problem Statement

Modern enterprise web code has become buried under defensive boilerplate: `TeamMemberInvitationServiceHandler`, `AbstractDataTransformerFactory`, and 400-line controller junk drawers. Developers spend more time satisfying plumbing, closing HTML tags, and dodging `NullPointerExceptions` than expressing domain logic.

Conversely, attempts to make code "expressive" in dynamic languages (like Ruby) often rely on un-traced runtime metaprogramming and hidden lifecycle callbacks that trigger spooky-action-at-a-distance bugs and confuse AI coding agents.

Caramel achieves **conceptual compression**: code that reads like concise, rhythmic English prose on the surface, while the compiler synthesizes strict, zero-allocation type safety and explicit database changesets underneath.

### 2. Technical Specification

#### 2.1. The Subject-Verb-Object Cadence

Domain operations are structured as subjects acting directly on objects via macro-synthesized methods, banishing intermediary "service nouns":

```crystal
# Caramel Poetic Cadence
team.invite("elena@acme.com", as: :admin) do |invite|
  invite.expires_in 7.days
  invite.deliver_via :email
end

```

* **Under the Hood:** The `invite` macro expands directly into a verified `Team::InviteChangeset`, validates tenant boundaries, and writes an enqueued `SendInvitationJob` into the PostgreSQL `caramel_jobs` table within the same transaction.

#### 2.2. Declarative Sentence Scopes

Database queries read as declarations of fact rather than relational arithmetic:

```crystal
overdue_invoices = Invoice.query
  .unpaid
  .past_due(by: 30.days)
  .preload(:customer)
  .order_by(:due_date, :asc)

Subscription.query.trialing.expired.each(&.terminate!)

```

#### 2.3. Semantic & Temporal Primitives

Caramel Core extends Crystal’s `Int` and `Time::Span` primitives with zero-allocation semantic units:

```crystal
publish_at   = 3.days.from_now.at_midnight
grace_period = 48.hours

if workspace.storage_used > 50.gigabytes
  workspace.lock_uploads!
end

ColdBrew::Job.retry_on Stripe::RateLimitError,
  attempts: 5,
  backoff: :exponential,
  base: 2.seconds

```

#### 2.4. Slang Template Engine (Whitespace as Structure)

Caramel Core adopts **Slang** (Crystal's native, whitespace-sensitive template engine) as its primary presentation syntax, eliminating tag soup:

```slang
/ src/app/views/teams/_card.slang
hx-partial hx-target="#team-#{team.id}" hx-swap="innerMorph"
  .team-card class=(team.active? ? "border-emerald" : "border-slate")
    header.flex.items-center.justify-between
      h3.font-serif.text-lg = team.name
      span.badge = team.plan.to_s.upcase

    p.text-sm.text-muted
      | Allocated: 
      strong = pluralize(team.seats, "seat")

    footer.mt-4
      button.btn-primary hx-post="/teams/#{team.id}/seats" hx-vals='{"seats": 1}'
        | Add Seat

```

#### 2.5. Single-Thought Vertical Slice Actions

Actions are isolated units of thought. Each action defines:

1. **Contract:** What input is accepted.
2. **Handle:** What domain rule executes.
3. **Egress:** What changes on the client’s screen.

```crystal
# src/app/actions/subscriptions/pause.cr
struct Subscriptions::Pause < Caramel::Action
  contract do
    field subscription_id : Int64
    field resume_at : Time?
    field reason : String, min: 5
  end

  def handle(contract : Contract)
    subscription = Subscription.query.find(contract.subscription_id)

    subscription.pause!(
      until: contract.resume_at || 1.month.from_now,
      reason: contract.reason
    )

    morph "#subscription-panel", with: Subscriptions::PanelPartial.new(subscription)
  end
end

```

#### 2.6. Artisan Terminal Typography

Human developer feedback is rendered with visual clarity and actionable remediation hints:

```text
  ╭─[ src/app/actions/billing/upgrade.cr:18 ]
  │
  │  18 │ team.users.each do |user|
  │     │      ^^^^^ Association 'users' was not preloaded.
  │
  ╰─ Accessing un-preloaded relationships triggers runtime N+1 queries.
     
     Remediation:
     Add .preload(:users) to the query in Billing::Upgrade before line 18:
     
     team = Team.query.preload(:users).find(team_id)

```

### 3. Failure Modes & Mitigations

* **Over-Clever DSLs Obscuring Execution Flow:** Highly expressive macros can become opaque, making it difficult for developers or agents to trace code paths.  
  *Mitigation:* Caramel Core enforces an invariant: all macros must compile down to explicit, standard Crystal code. Running `caramel expand <file>` outputs the generated Crystal code to demystify any abstraction.
* **Performance Tax on Semantic Extensions:** Semantic numbers and time spans (`3.days`, `50.gigabytes`) could introduce heap allocation overhead if implemented naively.  
  *Mitigation:* All temporal and numeric extensions are implemented as zero-allocation inline struct methods on primitive types, compiling directly down to LLVM integer constants.

---

## 4. System Invariant Verification Matrix

| Subsystem | Core Architectural Invariant | Enforcement Mechanism |
| --- | --- | --- |
| **Caramel Core (RFC-0001)** | No parameter-to-action contract drift. | Compile-time AST reflection via `Router.draw`. |
| **SugarORM (RFC-0002)** | Zero runtime N+1 query failures. | Association typed as `NotLoaded | Array(T)`. |
| **Caramel Cold Brew (RFC-0003)** | Zero dual-write data loss. | In-transaction enqueuing via PostgreSQL ACID boundaries. |
| **Caramel Latte (RFC-0004)** | Instant local iteration without Docker. | Host OS UNIX domain sockets and kernel kqueue/inotify. |
| **Caramel Frappé (RFC-0005)** | Low token overhead for AI coding loops. | Stateless POSIX CLI tools emitting compact MRDP text. |
| **Caramel Corretto (RFC-0006)** | Zero false-confidence test suites. | Subcutaneous testing against real Postgres branches. |
| **Caramel Roast (RFC-0007)** | Minimal infrastructure footprint. | Single static native binary (~25MB RSS) over SSH. |
| **Caramel Prose (RFC-0008)** | Conceptual compression without hidden callbacks. | Fluent facade macros expanding to pure changesets. |

---

## 5. Monorepo Repository Structure Blueprint

```text
caramel/
├── README.md                              # Manifest & Quickstart
├── ARCHITECTURE.md                        # This Document (RFCs 0001 - 0008)
├── shard.yml                              # Master workspace definition
│
├── bin/                                   # Compiled developer toolchain
│   ├── caramel                            # Primary POSIX CLI router
│   ├── latte                              # Host process & DB branch supervisor
│   └── roast                              # Static linking & deployment harness
│
├── src/
│   ├── core/                              # RFC-0001: Caramel Core runtime
│   │   ├── http/
│   │   │   ├── router.cr                  # Radix tree AST macro router
│   │   │   ├── action.cr                  # Base action handler & content negotiation
│   │   │   └── context.cr                 # Non-allocating request/response context
│   │   ├── contracts/
│   │   │   └── request_contract.cr        # Stack-allocated parameter coercion
│   │   ├── hypermedia/
│   │   │   ├── idiomorph.cr               # htmx 4 response builders
│   │   │   └── islands.cr                 # Web Component island wrapper (<caramel-island>)
│   │   └── prose/                         # RFC-0008: Temporal & semantic extensions
│   │       ├── semantic_numbers.cr
│   │       └── temporal_spans.cr
│   │
│   ├── orm/                               # RFC-0002: SugarORM
│   │   ├── schema.cr                      # Pure immutable struct macro
│   │   ├── changeset.cr                   # Pure validation & transformation boundary
│   │   ├── facade.cr                      # Fluent Active Record macro facade
│   │   ├── query.cr                       # Type-safe fluent query builder
│   │   ├── associations.cr                # Compile-time NotLoaded union types
│   │   ├── sql.cr                         # Typed SQL expression blocks
│   │   └── migrations/
│   │       ├── catalog.cr                 # pg_catalog introspection engine
│   │       ├── differ.cr                  # AST-to-catalog diff derivation
│   │       └── linter.cr                  # Zero-lock migration safety linters
│   │
│   ├── concurrency/                       # RFC-0003: Caramel Cold Brew
│   │   ├── queue.cr                       # SKIP LOCKED PostgreSQL transaction queue
│   │   ├── worker.cr                      # CSP Fiber pool supervisor
│   │   ├── sse.cr                         # LISTEN/NOTIFY Server-Sent Events broker
│   │   └── cache.cr                       # UNLOGGED table key-value cache facade
│   │
│   ├── dx/                                # RFC-0004: Caramel Latte
│   │   ├── supervisor.cr                  # Native host process runner (kqueue/inotify)
│   │   └── brancher.cr                    # Connection-guarded Postgres template cloner
│   │
│   ├── agent/                             # RFC-0005: Caramel Frappé
│   │   ├── manifest.cr                    # Agent discovery manifest generator
│   │   ├── tier1_checker.cr               # --no-codegen fast verification harness
│   │   └── mrdp.cr                        # Dual-mode diagnostic formatter (ANSI / MRDP)
│   │
│   ├── testing/                           # RFC-0006: Caramel Corretto
│   │   ├── runner.cr                      # Corretto test runner & savepoint harness
│   │   ├── assertions.cr                  # Observable hypermedia & DB state matchers
│   │   ├── queue_drainer.cr               # Synchronous queue execution coordinator
│   │   └── wire_stub.cr                   # Socket-level HTTP proxy for external APIs
│   │
│   └── ops/                               # RFC-0007: Caramel Roast
│       ├── compiler.cr                    # musl static binary compilation pipeline
│       ├── asset_inliner.cr               # Compile-time macro asset embedding
│       └── deployer.cr                    # SSH atomic socket handoff engine
│
└── packages/                              # The First-Party Five SDKs (RFC-0007)
    ├── caramel-billing/                   # Stripe API & Webhook verification
    ├── caramel-storage/                   # S3 / R2 / Local Disk streaming
    ├── caramel-mail/                      # Postmark / Resend / SMTP client
    ├── caramel-auth/                      # OAuth2, Passkeys & Session guards
    └── caramel-notify/                    # Twilio SMS & Web Push

```
