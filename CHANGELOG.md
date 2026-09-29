# Changelog

Caramel follows semantic versioning. During 0.x a minor release may break compatibility and a patch release never does ([ADR 0016](docs/decisions/0016-versioning-and-releases.md)). Write upgrade notes for the next release under Unreleased; `scripts/release` moves them into its section.

## Unreleased

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
