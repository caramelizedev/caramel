# Changelog

Caramel follows semantic versioning. During 0.x a minor release may break compatibility and a patch release never does ([ADR 0016](docs/decisions/0016-versioning-and-releases.md)). Write upgrade notes for the next release under Unreleased; `scripts/release` moves them into its section.

## Unreleased

## 0.7.0 - 2026-10-02

### Upgrade notes

- Caramel can translate an application ([ADR 0024](docs/decisions/0024-internationalization.md)). Nothing changes until it runs `frappe make locale CODE`. That command adds `app/locales/en.cr`, `app/locales/CODE.cr` and the `caramel/i18n` lines in `config/application.cr`. Resources generated after it are translated, and `frappe translations` lists the keys each locale still lacks. Resources generated before it keep their English text until you replace it with `t.` calls.
- In an existing application, change `html lang: "en"` in `app/views/layouts/application.cr` to `html lang: Caramel.language`, as new applications have it. For a right-to-left locale, also add `dir: locale.dir`.
- `Caramel::Application::EXPIRED_FORM` is removed; use `Caramel::Wording.expired_form`, which a catalog can translate. Caramel's other messages now come from `Caramel::Wording` and `SugarORM::Wording`, with the same English text as before.
- In a translated application, contract and changeset errors are in the request's locale, in pages and in JSON `errors` alike, and so is the router's 404 body (`caramel.pages.not_found`). A changeset built outside a request, such as in a Cold Brew job, uses the default locale unless the job wraps its work in `Caramel::I18n.with(locale) { … }`.

### Breaking changes

- **core:** move Caramel's messages into Wording hooks (46f8dc4)

### Features

- **core:** add opt-in internationalization with caramel/i18n (6f4b2fd)
- **frappe:** add make locale, translations and translated resources (ad93ca8)

## 0.6.1 - 2026-10-01

### Fixes

- **sugar-orm:** compile each write's query once (5ff1208)
- **core:** compile action egress once instead of once per action (be9b969)

## 0.6.0 - 2026-10-01

### Upgrade notes

- Installing this release creates a new managed toolchain directory because its compiler and
  Shards launchers changed. The first builds start with an empty compiler cache. Editor users
  must run `frappe lsp install` again; rebuilding crystalline can take about 20 minutes.
- Corretto adds Blueprint-shaped `have_html` expectations and content blocks for `render_partial`. Existing matcher calls still work; `render_page` now requires a real doctype. See [testing HTML](docs/testing.md). Lexbor 3.6.4 is a development dependency: existing applications must add it under `development_dependencies` and refresh `shard.lock` before `frappe setup`; generated apps include the pin. Development installs build it with `cc` and `ar` (Apple Command Line Tools on macOS or `build-essential` on Debian/Ubuntu). Production installs omit the parser entirely.
- HTML expectations check numeric leaf values, accept conditional nested class arrays, and join direct text across comments. Unsupported leaf values raise with a `.to_s` remedy. Table rows and cells inside `hx-partial` envelopes use htmx's template parsing context. The [production case inventory](docs/research/corretto-html-testing.md) records the regression coverage and functional authoring exercises.

### Features

- **corretto:** add Blueprint-shaped HTML expectations (8decb18)

### Fixes

- **corretto:** cover production HTML and authoring edge cases (5fd7b51)

## 0.5.1 - 2026-09-30

### Fixes

- **latte:** let only exact matches make a service adoption ambiguous (71c3916)

## 0.5.0 - 2026-09-30

### Upgrade notes

- Routes now bind a JSON object where they answered 415 ([ADR 0020](docs/decisions/0020-action-ingress-and-json-bodies.md)). Each member must have its field's JSON type, and same-origin `fetch` sends the page's CSRF token as `X-CSRF-Token`. An application that reopened `Caramel::RequestInput` to parse JSON, or `Caramel::Application#handle` to receive a webhook, should delete the reopen: bind JSON through the contract, or declare `ingress body: :raw, limit: 256.kilobytes, csrf: false, authenticate: :signed?` on the webhook's action.
- `Caramel::RequestInput.read(request, max_form_bytes: n)` still works for 1 byte to 64 MiB, and raises `ArgumentError` outside that range. It is deprecated; pass the route's policy instead, as `Caramel::RequestInput.read(request, Caramel::Ingress.new(limit: n))`. A body that is neither a form nor a JSON object now answers 415 with "Expected a URL-encoded form, multipart form or JSON object".
- A custom `Caramel::Router::Dispatcher` must implement `match(request)` and `dispatch(context, match)`. Routers from `Caramel::Router.draw` already do.
- A form's `_method` override into a route whose `ingress` reads the body differently (another body, limit or CSRF setting) answers 405: that route is reached with its real method.
- The router now builds the action before its contract binds, so that an authenticator can run first. An action's own `initialize` therefore also runs for requests that end in a route 404 or a contract failure.
- Specs never received the development `.env` and still do not. Put test-only settings the application reads itself, such as `WEBHOOK_SECRET`, in a committed `.env.test`. `frappe new` now adds one.
- Instead of querying `caramel_jobs`, read a job with `Caramel::ColdBrew.status(id)` and learn of retries and failures with `on_retry_scheduled` and `on_failed` ([ADR 0019](docs/decisions/0019-cold-brew-status-hooks-and-work.md)). Jobs run at least once, so a job that calls another service should send it a stable identifier to deduplicate.
- To run workers without a web server, start the application binary with `work`, optionally with `--queues=`, `--concurrency=` and `--no-scheduler`.
- If `frappe dev` in an existing project stops on an asset output conflict, delete the public file it names to republish it from `app/assets`.
- `scripts/crystal`, the compiler launcher, changed, so installing this release sets up a new toolchain directory and its first builds start with an empty compiler cache. If you use the editor tools, run `frappe lsp install` again after installing; rebuilding crystalline takes up to about 20 minutes. In the first editor session afterwards, go to definition into Crystal's standard library can find nothing until you save the file once.
- Each compile now starts with a 1 GB heap, which uses about 250 MB more memory per compiler and saves most of its early garbage collections. Set `GC_INITIAL_HEAP_SIZE` yourself to choose another size.

### Features

- **frappe:** give specs the application's test settings from .env.test (cb7c730)
- **core:** run Cold Brew without HTTP with the work command (e0c83d2)
- **core:** report job status and call hooks after a failure is written (788b26c)
- **core:** let an action declare how its route reads the request (7740df1)
- **core:** send JSON, uploads and raw bodies from Corretto's client (3c8a9c1)
- **frappe:** mark URL resource fields with :url (0283a82)
- **core:** answer errors found after the contract with render_errors (2119c5d)
- **frappe:** generate only the resource actions --only names (ace706e)

### Fixes

- **frappe:** forward bodiless responses through the dev gateway (8a29a35)
- **core:** treat a closed stream as a disconnect, not an error (986c29b)
- **frappe:** record the assets a new project publishes (c918e2f)
- **release:** skip the migration probes when nothing they compile changed (f9cedf9)
- **core:** hold every ingress to the authenticator it names (b1f72b1)
- **checks:** verify the session's compiler and keep the lint proofs strict (8e17b8b)
- **frappe:** load the saved row in a request spec only when a check reads it (f82fe02)
- **core:** refuse a subtype ingress that drops its parent's authenticator (9fcafe0)
- **frappe:** run frappe dev's build for commands over the same sources (831971c)
- **corretto:** keep each worker's spec binary while its inputs are unchanged (58135a2)
- **corretto:** build spec binaries while the application migrates (b4f4fae)
- **core:** let crystal tool expand read the work command's options (e10b6dc)
- **core:** let frappe expand parse the work command's options again (551b9dc)
- **frappe:** make the dev build's semantic phase its Tier-1 type check (93365c6)
- **toolchain:** start the compiler with a 1 GB heap (e7d8ee6)
- **toolchain:** skip scripts/crystal's metadata rewrite when nothing changed (7b54d5a)
- **toolchain:** give each checkout program its own compiler cache root (ccaa191)

## 0.4.3 - 2026-09-29

### Fixes

- **frappe:** trim the dev loop's fixed waits (bf92bd3)
- **frappe:** build one-shot commands with the dev build's define (949f9e2)
- **corretto:** compile each worker from a stable entry file (87a508d)

## 0.4.2 - 2026-09-29

### Upgrade notes

- Caramel now pins Crystal 1.21.1, which fixes `Socket#connect` on macOS 26.7 and later and closes `HTTP::Server` request-smuggling and request-body decompression issues. Installing this release sets up a new toolchain directory, so its first builds start with an empty compiler cache.
- If you use the editor tools, run `frappe lsp install` again after installing: crystalline rebuilds against the new compiler, which takes up to about 20 minutes. In the first editor session afterwards, go to definition into Crystal's standard library can find nothing until you save the file once.
- New applications declare `crystal: ">= 1.21.1"` in `shard.yml`.

### Fixes

- **installations:** build a release's parts side by side (9ce40a9)
- **toolchain:** pin Crystal 1.21.1 for its macOS socket and HTTP server fixes (24f984f)

## 0.4.1 - 2026-09-29

### Fixes

- **release:** run the two migration probes side by side (061ec9a)

## 0.4.0 - 2026-09-28

### Upgrade notes

- `redirect_external` now refuses URLs with credentials (`https://user:pass@host/`) or whitespace, and `Caramel::Outbound` now refuses backslashes: both follow `Caramel::ExternalURL`, which `cs.validate_url(:field)` also applies when saving.
- A frappe older than 0.3.0 installs releases without their linter. If one installed this release, run the same `frappe installations install` command again to build it; `frappe doctor` names that command.

### Features

- **frappe:** build releases with their own script and finish installs that lack a linter (9e876d9)
- **frappe:** declare unique resource fields with :unique (fb7403f)
- **core:** share one external URL rule with cs.validate_url (951087f)

## 0.3.0 - 2026-09-28

### Upgrade notes

- Nothing in a 0.2.0 application has to change. To adopt the layout `frappe new` now generates, pass it the page: `ApplicationAction#layout` calls `Views::Layouts::Application.new(page, csrf_token).to_s`, and `app/views/layouts/application.cr` takes `(@page : Caramel::Page, @csrf_token : String)`, titles the document with `@page.title` and writes the body with `raw @page.html`.

### Features

- **frappe:** build the linter when installing a release (ae4c575)
- **core:** give layouts the page body as trusted HTML (68dda7e)
- **core:** build small fragments inline with markup (962db90)
- **core:** redirect to other sites deliberately with redirect_external (687c270)
- **frappe:** mark resource fields the server sets with :server (1b4392d)

## 0.2.0 - 2026-09-28

### Upgrade notes

- Views are Blueprint classes ([ADR 0018](docs/decisions/0018-blueprint-views.md)). ECR views, `Caramel::View.render`/`embed`, `view "..."` and `scripts/check views` are removed without a deprecation release; the only ECR applications were demos. To port an application:
  - rewrite each `app/views/**/*.html.ecr` as a class in `app/views/**/*.cr`: `app/views/<dir>/<name>.cr` defines `App::Views::<Dir>::<Name> < App::ApplicationView`, with typed inputs in `initialize` and markup in `private def blueprint`;
  - add `app/views/application_view.cr` (`abstract class App::ApplicationView < Caramel::View`, including `App::Paths`), as `frappe new` generates it;
  - in `config/application.cr`, require `../app/views/application_view` and then `../app/views/**` before the actions;
  - replace `view("x", a: b)` with `Views::X.new(b)`, for example `page "Books", Views::Books::Index.new(records)`, and the layout call in `ApplicationAction#layout` with `Views::Layouts::Application.new(page.title, Caramel::HTML::Safe.new(page.body), csrf_token).to_s`;
  - pass `csrf_token` to views that render forms;
  - in `.ameba.yml`, glob `app/**/*.cr` and exclude `app/views/**/*.cr` from `Lint/DebugCalls`.

### Breaking changes

- **core:** views are Blueprint classes (62b658d)

### Features

- **core:** add RFC-0008 byte sizes and Time#at_midnight (d8849ec)

### Fixes

- **latte:** adopt a postmaster another toolchain's build started (c327e36)
- **release:** read released framework migrations through a relative require (60cd6d3)
- **release:** refuse when the released tree cannot be extracted (dcdf2a7)

## 0.1.0 - 2026-09-28

### Features

- verify and document the isolated Caramel toolchain (17b3e3c)
- add Crystal runtime and PostgreSQL Bookshelf reference (93eb38f)
- add Latte managed services and native macOS controls (0fe4225)
- add typed models and browser form inputs (de32e39)
- add resumable private toolchain installer (72cc093)
- add Frappé project setup and typed resource generation (d59a914)
- add supervised development builds and local browser refresh (08e84be)
- add development exception pages and live project status (84f3aee)
- add Caramel Core routing, contracts and hypermedia (0488689)
- stream responses and adopt RFC-0008 action ergonomics (1ef1f46)
- **orm:** add SugarORM with derived, linted migrations and remove Caramel::Model (b47a9f1)
- **cold-brew,corretto:** add PostgreSQL jobs, PubSub and cache, and the Corretto test harness (8701c36)
- **latte:** watch with kqueue, type-check before building, clone branches with APFS and release guards on signals (13e1181)
- **frappe:** drive the CLI from one command table and add check, agent-manifest, db branch and expand (0a0a600)
- **latte,frappe:** find the toolchain through the checkout's .caramel-toolchain (6eae808)
- **installer:** default the toolchain root and record it for the checkout (0711fe5)
- **frappe:** put frappe and latte on PATH when registering a checkout (a5baa14)
- **latte,frappe:** start Latte on demand and stop it with latte stop (190be9b)
- **latte:** add an opt-in login item with latte service install (1bb41af)
- adopt the RFC-0008 rule set, with frappe lint and frappe format (ADR 0017) (2d1ca25)
- version the release and the Frappé–Latte contracts (ADR 0016) (2ba457c)
- generated apps depend on Caramel as a shard, with a one-call main (ADR 0016) (03a34e5)
- install tagged releases, run the newest Latte, and cut releases with scripts/release (ADR 0016) (d1673eb)

### Fixes

- record generated application edit-loop baselines (b5d8c2f)
- retire old development apps without blocking new builds (f4af078)
- **latte:** serve .localhost sites and never install Caddy CA trust (e8b8ef3)
- **core:** keep focus and island state across morphs (0268f72)
- **latte:** stop the daemon cleanly and tolerate Caddy restarts in checks (9389351)
- **cold-brew:** bound the security-definer partition functions (a2d2142)
- **latte:** let the port relay accept launchd's listening sockets (c7fd9d9)
- **frappe:** migrate new projects and report pending migrations once (76447d2)
- **latte:** say latte stop leaves services as they were (e11eaa8)
- **installer:** rerun the recorded toolchain when no root is given (cf7f5d6)
- **latte:** detach before loading the registry (1419cae)
- **installer:** validate the recorded pointer before reusing its toolchain (c0ff474)
- **frappe:** require the installed-releases reader where Latte starts (cf45846)
- close the ADR 0016 and 0017 audit findings (a4bc807)
