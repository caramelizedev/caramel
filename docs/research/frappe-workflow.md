# Frappé generated-project workflow

This is an implementation preview on `codex/frappe-application-workflow`, not a consumer release. The framework and toolchain are pinned; consumer launchers and browser acceptance remain open. Independent review is pending while the requested Luna workers are unavailable.

## Implemented interface

`scripts/build-frappe` builds `bin/frappe`. Set `CARAMEL_TOOLCHAIN_ROOT` to the verified private installation and run Latte's shared daemon before using project setup. Frappé communicates through Latte's owned Unix socket. It waits for managed services when necessary, but does not install or bootstrap a missing daemon.

```sh
frappe new bookshelf
cd bookshelf
frappe make resource Book title:string author:string
frappe migrate
frappe routes
frappe test
```

The binary also implements `setup`, `dev`, `seed`, `services`, `sites`, `doctor` and `open`. See [development workflow](frappe-development.md) for watcher ownership, build diagnostics, refresh and verification limits. Help is authoritative for currently available commands. `open` checks system DNS and certificate trust before opening the URL. `doctor` checks project metadata, framework snapshot, managed compiler, installed dependencies, PostgreSQL tool, private configuration, service state and named HTTPS; it does not repair state.

`new` writes the complete starter before invoking locked Shards installation. An interrupted dependency step retains the project and directs the user to `setup`. Setup preserves application edits and existing valid secrets; it refuses mismatched credentials. Compilation uses the main target in `shard.yml`, independently of the local site name. A simultaneous clone needs a distinct name in `config/environment.yml` because two directories cannot own the same local origin.

## Source and secrets

The versioned environment manifest records its schema version, project name, PostgreSQL major, requested extensions and domain suffix. This release accepts PostgreSQL 18 and three suffixes:

- `.caramel`, the default;
- `.test`, which must be chosen explicitly;
- `.localhost`, which must be chosen explicitly. macOS and browsers resolve `.localhost` names to loopback without a resolver entry (RFC 6761); see [ADR 0006](../decisions/0006-browser-acceptance-and-localhost-sites.md).

Extension names are validated metadata; automatic extension provisioning is not implemented.

Latte supplies four distinct connection URLs over owner-only IPC: development runtime/migration and spec runtime/migration. Frappé writes them with a fresh application secret to mode-0600 `.env`. Temporary secret files stay under ignored, private `.caramel/`. Neither public status nor site listings include these credentials.

The unpublished preview includes the framework under `vendor/caramel`, with a version and per-file checksum manifest. The application lock pins that source plus crystal-db 0.14.0 and crystal-pg 0.30.0. Setup verifies the project's own snapshot and installs with `--frozen`; it does not silently replace source with the latest checkout. The manifest detects accidental drift, not a maliciously modified manifest and source pair.

## Generated resources

`make resource` takes a singular class name and `field:type` declarations. Supported types are `string`, `int32`, `int64`, `bool`, `float64` and RFC 3339 `time`, optionally nullable with `?`. Quote nullable declarations in globbing shells. Ordinary plurals follow a small predictable inflector; irregular names use `--plural=people`.

Generated source contains:

- a SugarORM schema (`app/models/<singular>.cr`);
- one changeset, `App::<Name>::Changeset`, aliased as `CreateChangeset` and `UpdateChangeset` so that `App::<Name>.create` and `record.update` both use it (`app/changesets/<singular>.cr`);
- seven actions (index, show, new, create, edit, update, destroy) with their request contracts, and a shared form module;
- five views, including the shared form;
- the `create_<plural>` migration;
- route and path declarations;
- a request spec.

The changeset refuses blank required strings. Actions write through the facade: create calls `App::Book.create(...)` and update calls `record.update(...)`. Each re-renders the form with status 422 and the changeset's errors unless it reports `saved?`. Destroy calls `record.delete`, and show and edit read with `App::Book.query.find(id)`. Index pages show the newest 100 rows through `App::Book.query.order_by(:id, :desc).limit(100)`; pagination and associations are outside this generator's current scope.

The generator builds the new table's catalog and diffs it against an empty database with `SugarORM::Differ`, offline. It writes exactly the file that `frappe db diff --name create_<plural>` would derive for the generated schema. Later schema changes go through `frappe db diff`. Schemas, changesets and actions use a fixed `App` namespace. Field names that would collide with system columns, the schema DSL, the facade, changeset or request contract APIs, or Crystal keywords are refused. All generated files are application-owned and editable.

Routes are explicit verb declarations inside the single `Caramel::Router.draw` block in `config/routes.cr`:

```crystal
get "/books/:id", App::Books::Show
patch "/books/:id", App::Books::Update

# Inside App::Paths, included by ApplicationAction:
Caramel.resource_paths :books, :book
```

Each route is checked at compile time: the action must exist, inherit from `Caramel::Action` and declare a `contract do ... end` block, every `:param` must be a non-nilable `String`, `Int32` or `Int64` contract field, and duplicate or ambiguously ordered routes are rejected. `frappe routes` prints each route with its contract summary. Invalid, negative or overflowing member IDs return 404. Native HTML forms submit POST with a CSRF-checked `_method`; direct PATCH/DELETE routes are generated, PUT is not. Normal success navigates with a 303 redirect, and enhanced requests receive `HX-Location`. Invalid input renders 422 with submitted values and field errors for browsers, `{"errors": ...}` for JSON clients and a plain-text diagnostic for other clients. Clients sending `Accept: application/json` receive each action's result as JSON. All ECR expressions escape by default; only compiled partial composition uses the explicit trusted HTML type.

Generation preflights every destination and requires a unique insertion marker in routes and paths. Existing files and source conflicts are refused. Writes are staged, serialized by a project lock, and ordinary write failures roll back published source if it has not changed again. This is not a crash-atomic multi-file filesystem transaction; a process or machine crash can require manual inspection before retrying. Concurrent external editors are not coordinated by that lock.

## Verification

`scripts/check frappe-project` executes the real CLI in disposable state. It creates Book and mixed-scalar Person resources, compiles the app and applies migrations. `frappe migrate` must report that the database matches the declared schemas, and `frappe db diff --name drift_probe` must find nothing to derive and write no file, which proves that the generated migrations are exactly what the differ derives. The check then runs the generated request specs against separately provisioned PostgreSQL databases. Those specs exercise persisted create/update/delete through the SugarORM facade, rendering, escaping, CSRF rejection, invalid-input responses, blank-text refusal by the generated changeset on create and update, and native/enhanced response contracts. The harness also checks clone setup with fresh credentials, retained edits, failed dependency installation followed by setup recovery, and development data retention when running specs. Pointing the spec URL at development is refused before migration or test execution.

The final HTTP check serves the generated application through Caddy on a private test port with a named Host and an explicitly supplied fixture CA. It establishes native app/proxy/TLS behavior. It does not establish system DNS, browser certificate trust or public port 443. `scripts/check browser` covers real htmx interaction in Safari against a `.localhost` fixture site.

Unit specs cover configuration, literal environment parsing, secret preservation, private IPC, generation conflicts, reserved field names, byte equality between a generated migration and the differ's derivation, route binding, redirects and CLI grammar. `scripts/check route-compilation` verifies that undefined actions, missing contracts, route/contract mismatches, duplicate or ambiguous routes and wrong path-helper types fail compilation. `scripts/check schema-diff` covers `frappe db diff` end to end.

## Remaining gates

- Complete development acceptance: real browsers, runtime exception diagnostics, CLI/menu project state and measured performance. The watcher, build-error recovery, isolated child ownership and asset publishing are implemented.
- Individual model/action/migration/command generators, custom commands, explicit dependency add/update and spec worker isolation.
- A committed schema snapshot file. The application's `schema` command prints the declared catalog, and migrations remain authoritative.
- Complete optional authentication, native Linux/musl production artifact and its assets/configuration.
- Full macOS installation, native menu acceptance, system DNS/ports, CA trust and real browser CRUD, including htmx history/focus/422 handling and JavaScript-disabled forms.
- Independent implementation review and clean-machine installation proof.
