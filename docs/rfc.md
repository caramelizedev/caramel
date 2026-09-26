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

**Status:** Approved

**Classification:** Foundational Architecture

**Component:** `caramel-core`

### 1. Context & Problem Statement

Traditional web monoliths couple routing, parameter extraction, and view rendering through dynamic runtime lookups (e.g., Rails `params[:id]`, Laravel `$request->input('id')`). This causes runtime type crashes, dynamic allocation overhead, and silent contract drift between route definitions and controller handlers. On the frontend, client-heavy frameworks force teams into separate build pipelines (Node/Vite) and complex client-side state hydration, while dogmatic hypermedia setups struggle when building complex canvas or drag-and-drop tools.

Caramel Core provides an opinionated, statically compiled full-stack runtime written in Crystal. It eliminates client-side bundlers by pairing an AST macro router with an **htmx 4** hypermedia pipeline, statically verified **RequestContracts**, dual wire-egress capabilities, and an official Web Component island escape hatch (**Caramel Islands**).

### 2. Technical Specification

#### 2.1. Compile-Time Macro Router (`Caramel::Router`)

Routes are registered inside a `Caramel::Router.draw` block. When a route contains dynamic segment tokens (`:param_name`), the macro engine inspects the target Action’s nested `Contract` struct using Crystal's macro introspection methods (`@type.constant("Contract").instance_vars`).

* **Verification Rule:** If a route declares `/:team_id` and the Action’s `Contract` lacks an instance variable `team_id`, or if the types are incompatible, compilation terminates immediately via `{{ raise }}`.
* **Dispatch Table:** The router expands into an inlined, non-allocating radix tree dispatch method without runtime regex evaluation.

```crystal
# src/caramel/http/router.cr
module Caramel::Router
  macro draw(&block)
    class AppRouter
      def call(context : HTTP::Server::Context)
        path = context.request.path
        method = context.request.method

        {{ block.body }}

        context.response.status_code = 404
        context.response.print("Not Found")
        context
      end
    end
  end

  macro route(http_method, path, action)
    {% tokens = path.split("/").select { |t| t.starts_with?(":") }.map { |t| t.gsub(/^:/, "") } %}

    {% unless action.resolve? %}
      {{ raise "Compile Error: Action '#{action}' is undefined." }}
    {% end %}

    {% contract = action.resolve.constant("Contract") %}
    {% unless contract %}
      {{ raise "Compile Error: '#{action}' must define an explicit `contract do ... end` block." }}
    {% end %}

    {% contract_fields = contract.instance_vars.map(&.name.stringify) %}
    {% for token in tokens %}
      {% unless contract_fields.includes?(token) %}
        {{ raise "\n\n❌ ROUTE CONTRACT MISMATCH\nRoute: '#{path.id}' defines parameter ':#{token.id}'\nAction: '#{action.id}::Contract' is missing 'field #{token.id} : Type'\n" }}
      {% end %}
    {% end %}

    if method == {{ http_method }} && path_matches?({{ path }}, path)
      params = extract_params({{ path }}, path, context)
      contract_instance = {{ action }}::Contract.from_hash(params)
      action_instance = {{ action }}.new(context)

      if contract_instance.valid?
        return action_instance.handle(contract_instance)
      else
        return action_instance.render_contract_failure(contract_instance)
      end
    end
  end
end

```

#### 2.2. Request Contracts (`Caramel::RequestContract`)

Input validation is decoupled from the database layer. All query params, route parameters, and form-encoded bodies pass through stack-allocated structs that perform coercion, bounds checking, and error aggregation without heap allocations.

```crystal
# src/caramel/contracts/request_contract.cr
abstract struct Caramel::RequestContract
  getter errors = Hash(String, Array(String)).new

  def valid? : Bool
    @errors.empty?
  end

  macro schema(&block)
    {{ block.body }}
  end

  macro field(decl, min = nil, max = nil, default = nil)
    property {{ decl }} {% if default != nil %} = {{ default }} {% end %}
  end
end

```

#### 2.3. Hypermedia Egress (htmx 4 + Idiomorph)

The default presentation engine targets **htmx 4**:

* **Morph Streaming:** Responses use built-in idiomorph swapping (`swap="innerMorph"`) to preserve DOM focus and scroll position.
* **Multi-Target Ingestion (`hx-partial`):** A single controller invocation can target multiple disjoint elements on the page in a single round-trip:

```html
<hx-partial target="#team-roster" swap="innerMorph">
  <div id="member-42" class="member-row">Jane Doe</div>
</hx-partial>
<hx-partial target="#seat-counter" swap="innerHTML">
  <span>14 / 20 Seats Used</span>
</hx-partial>

```

#### 2.4. The Island Escape Hatch (`Caramel Islands`)

To prevent the "htmx-only complexity cliff" when developers need rich client-side interactivity (spreadsheets, canvas tools, drag-and-drop workflow builders), Caramel Core provides official Web Component wrappers. These components receive server-rendered data attributes and isolate client-side frameworks without turning the application into an SPA:

```html
<div class="canvas-container">
  <h2>Workflow Designer</h2>
  <caramel-island 
    component="WorkflowCanvas" 
    props="<%= { nodes: workflow.nodes, edges: workflow.edges }.to_json %>">
  </caramel-island>
</div>

```

#### 2.5. Dual Egress Protocol

Every Action automatically performs content negotiation based on inbound headers:

1. `HX-Request: true` $\to$ Returns the compiled HTML fragment / `<hx-partial>`.
2. `Accept: application/json` $\to$ Bypasses HTML generation entirely, serializing the Action's assigned internal response struct directly to JSON for native mobile clients or external consumers.

---

# RFC-0002: SugarORM (Data Layer, Pure Schemas, & Evolution)

**Status:** Approved

**Classification:** Core Data Architecture

**Component:** `sugar-orm`

### 1. Context & Problem Statement

Active Record implementations (Rails, Laravel) merge business logic, persistence, and lifecycle hooks into heavy "God Objects." Callbacks (`after_save`, `before_validation`) produce hidden side-effects that make automated code reasoning perilous for AI agents. Conversely, overly academic functional ORMs strip away developer happiness, forcing verbose transaction scripts for basic updates. Furthermore, un-preloaded relationships cause production N+1 query failures, while hand-authored migration files regularly drift out of sync with declared models.

SugarORM is an Ecto- and Drizzle-inspired data layer for Crystal featuring a **Fluent Active Record Facade** over pure immutable schemas, explicit changesets, compile-time association safety, and auto-derived migrations via PostgreSQL catalog diffing.

### 2. Technical Specification

#### 2.1. Pure Schemas & Compile-Time Association Safety

Schemas are immutable structs representing rows in PostgreSQL. They contain zero connection handles and zero hidden lifecycle hooks. Relationships are typed as compile-time unions containing an explicit `NotLoaded` sentinel:

$$\text{Association}(T) = \text{SugarORM::NotLoaded} \mid \text{Array}(T)$$

```crystal
# src/app/models/team.cr
struct Team < SugarORM::Schema
  schema "teams" do
    field id : Int64, primary: true
    field name : String
    field seats : Int32 = 5
    field billing_email : String?
    
    # Typed relation union prevents compile if un-preloaded
    has_many users : User
  end
end

```

#### 2.2. Idiomatic Association Helpers

To preserve compile-time safety without burdening human developers with verbose `case/when` syntax, SugarORM synthesizes unwrapping helpers directly on associations:

```crystal
# Idiomatic helper unwraps the loaded state cleanly:
team.users.each do |user|
  # If .preload(:users) was omitted on the query, this raises a deterministic
  # Compile Error at build time, preventing silent production N+1 queries.
  puts user.email
end

```

#### 2.3. The Fluent Facade: Ergonomics on Surface, Purity Underneath

Developers can write expressive, single-line updates without instantiating verbose Changeset objects manually. The macro engine synthesizes an explicit Changeset and executes it through the Repo behind the scenes:

```crystal
# 1. Developer-Facing Fluent Ergonomics (Rails/Laravel Happiness)
team.update(seats: 10, billing_email: "billing@acme.com")

# 2. What the Macro Expands to Under the Hood:
changeset = Team::UpdateChangeset.new(team, seats: 10, billing_email: "billing@acme.com")
SugarORM::Repo.update(changeset)

```

#### 2.4. Explicit Mutation Changesets (Advanced Operations)

When complex validations, casting, or conditional checks are required, developers or agents author explicit Changesets:

```crystal
# src/app/changesets/team_changeset.cr
struct Team::UpdateChangeset < SugarORM::Changeset(Team)
  param seats : Int32
  param billing_email : String?

  def validate(cs)
    cs.validate_greater_than(:seats, 0)
    cs.validate_format(:billing_email, /^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$/)
  end
end

```

#### 2.5. The Branch-and-Diff Migration Engine

Developers and agents never manually write SQL migrations. They modify the `schema` block in Crystal, and the engine derives the delta:

1. **Catalog Snapshot:** Spawns an ephemeral PostgreSQL branch via Latte (`CREATE DATABASE diff_scratch TEMPLATE dev_db`).
2. **Schema Introspection:** Queries the branch’s `pg_catalog` (tables, columns, indexes, foreign keys).
3. **AST Comparison:** SugarORM compiles a headless binary that dumps the target AST schema definition.
4. **DDL Derivation:** Computes the structural diff and outputs an immutable, timestamped migration file.

#### 2.6. Production Zero-Lock Migration Linters

The migration compiler enforces three non-negotiable rules:

* **Rule 1 (Concurrent Indexing):** All `ADD INDEX` operations must be emitted as `CREATE INDEX CONCURRENTLY`. Standard blocking index DDL fails the lint check.
* **Rule 2 (Non-Null Additions):** Adding a column with `null: false` without a default value is rejected by the linter, preventing table rewrites on populated tables.
* **Rule 3 (Rename Safety):** Renaming a field requires an explicit `renamed_from: :old_col` AST directive. If missing, the diff engine refuses to emit a destructive `DROP COLUMN` and halts with a diagnostic.

---

# RFC-0003: Caramel Cold Brew (Concurrency, Queues, & Real-Time PubSub)

**Status:** Approved

**Classification:** Concurrency & Real-Time Engine

**Component:** `caramel-cold-brew`

### 1. Context & Problem Statement

Traditional architectures rely on external dependencies (Redis, RabbitMQ, Memcached, Sidekiq) to manage asynchronous workloads, caching, and real-time messaging. This introduces distributed system failure modes, network hop latency, operational cost, and the **dual-write problem**—where database writes succeed but message queue pushes fail.

Caramel Cold Brew collapses this entire infrastructure footprint into PostgreSQL and Crystal’s fiber-based CSP concurrency model.

### 2. Technical Specification

#### 2.1. The Atomic Queue Substrate (`SKIP LOCKED`)

All background jobs are written to the `caramel_jobs` table inside the *same database transaction* as application business logic.

```sql
CREATE TABLE caramel_jobs (
  id BIGSERIAL PRIMARY KEY,
  queue TEXT NOT NULL DEFAULT 'default',
  class_name TEXT NOT NULL,
  payload JSONB NOT NULL,
  priority INT NOT NULL DEFAULT 0,
  attempts INT NOT NULL DEFAULT 0,
  run_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  locked_at TIMESTAMPTZ,
  locked_by TEXT,
  failed_at TIMESTAMPTZ,
  last_error TEXT
);

CREATE INDEX idx_caramel_jobs_fetch 
ON caramel_jobs (queue, run_at, priority DESC) 
WHERE locked_at IS NULL AND failed_at IS NULL;

```

#### 2.2. Worker Fiber Loop

Cold Brew spawns a configurable pool of green execution fibers within the single host binary:

```crystal
# src/caramel/cold_brew/worker.cr
module Caramel::ColdBrew
  class Worker
    def initialize(@queue = "default", @concurrency = 16)
    end

    def start
      @concurrency.times do
        spawn do
          loop do
            job = poll_next_job(@queue)
            if job
              process(job)
            else
              sleep 50.milliseconds
            end
          end
        end
      end
    end

    private def poll_next_job(queue : String) : Job?
      query = <<-SQL
        WITH selected AS (
          SELECT id FROM caramel_jobs
          WHERE queue = $1 AND run_at <= NOW() AND locked_at IS NULL AND failed_at IS NULL
          ORDER BY priority DESC, id ASC
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        UPDATE caramel_jobs
        SET locked_at = NOW(), locked_by = pg_backend_pid()::text, attempts = attempts + 1
        WHERE id = (SELECT id FROM selected)
        RETURNING id, class_name, payload, attempts;
      SQL
    end
  end
end

```

#### 2.3. Real-Time PubSub via SSE

Cold Brew eliminates WebSockets for hypermedia updates. It dedicates a pool of listener fibers to PostgreSQL's `LISTEN / NOTIFY` stream, bridging database events directly into Server-Sent Events (SSE) connections running over HTTP/1.1 or HTTP/2.

```crystal
struct Boards::Live < Caramel::Action
  def handle(contract : Contract)
    context.response.content_type = "text/event-stream"
    context.response.headers["Cache-Control"] = "no-cache"

    channel = Channel(String).new
    Caramel::ColdBrew.subscribe("board_#{contract.board_id}", channel)

    loop do
      payload = channel.receive
      context.response.print "event: BoardUpdated\ndata: #{payload}\n\n"
      context.response.flush
    end
  end
end

```

#### 2.4. Cache Subsystem via `UNLOGGED` Tables

The `Caramel::Cache` facade wraps an `UNLOGGED` PostgreSQL table that bypasses WAL writes entirely. Reads and writes execute in microseconds over UNIX domain sockets, supporting TTL expirations through an automatic background vacuum fiber.

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

---

# RFC-0006: Caramel Corretto (Zero-Mock Integration Testing)

**Status:** Approved

**Classification:** Quality Assurance & Verification

**Component:** `caramel-corretto`

### 1. Context & Problem Statement

Mock-driven unit tests provide a false sense of security. They test whether internal stubs were called with expected strings rather than verifying real production behavior. Full-stack browser automation (Playwright, Selenium) is brittle and slow, while naive database integration testing causes massive test-suite slowdowns. Furthermore, background queue execution in tests often results in race conditions that force developers into flaky `sleep()` loops.

Caramel Corretto enforces an **integration-first, zero-mock testing harness** that verifies application behavior subcutaneously against real PostgreSQL branches, synchronous queue drains, and real morphed HTML with sub-millisecond per-test isolation.

### 2. Technical Specification

#### 2.1. The Subcutaneous Testing Boundary

Corretto asserts exclusively against **observable ingress, database state, and hypermedia egress**. Mocking internal Crystal classes or methods is strictly forbidden.

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

#### 2.2. Three-Tier Isolation Lifecycle

1. **Tier 1 (Worker Suite Boot):** Spins up one isolated database branch per parallel test worker thread using Latte (`CREATE DATABASE worker_1 TEMPLATE caramel_test_template`).
2. **Tier 2 (Per-Test Savepoints):** Every `it` block runs inside a PostgreSQL `SAVEPOINT`. Upon test completion, `ROLLBACK TO SAVEPOINT` executes in **<1ms**, eliminating catalog cloning overhead between individual tests.
3. **Tier 3 (Catalog Reset):** The branch is torn down and recreated only if un-rollbackable DDL operations are executed.

#### 2.3. Synchronous Queue Drain Mode

In an integration test, background asynchronous polling is a liability. Corretto forces Cold Brew into **Synchronous Queue Drain Mode**:

* Fibers do not poll in the background during tests.
* The test harness explicitly executes all enqueued jobs on demand via `Caramel::ColdBrew.drain_queue!(db, "queue_name")`.
* Tests never write `sleep()` statements.

#### 2.4. Wire-Level External Fakes

External third parties (Stripe, Twilio, AWS) are never mocked by monkey-patching language methods. Corretto runs a lightweight, local socket-level HTTP proxy that matches incoming outbound requests and returns static, recorded responses:

```crystal
Corretto.stub_wire("https://api.stripe.com/v1/customers")
  .to_return(status: 200, fixture: "stripe/customer_created.json")

```

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
hx-partial target="#team-#{team.id}" swap="innerMorph"
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
