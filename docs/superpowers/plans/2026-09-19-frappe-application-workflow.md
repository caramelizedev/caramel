# Frappé application workflow implementation plan

> Use superpowers:subagent-driven-development. Implement bounded tasks in isolated worktrees, review specification compliance and quality, then integrate verified results.

**Goal:** The creator can install the supported environment, create a Crystal application, generate Book CRUD, migrate, edit, test and build it through Frappé. This follows the Latte local environment gate and precedes the optional-authentication completion gate; it does not replace either.

**Existing foundations:** HTTP/router/controller/escaped compiled view/form/CSRF primitives, verified PostgreSQL driver/pooling/migrations, managed toolchain experiment, and Latte's private registry/service API. Bookshelf is currently hand-authored and must become an integration fixture for the actual generator.

## 1. Typed application APIs

- [x] Evaluate current maintained Crystal model/form libraries against the exact required syntax and dependency constraints; document the reuse versus narrow implementation choice.
- [x] Implement the declared model class API needed by generated Book CRUD: typed fields and primary key, timestamps, presence validation, parameterized insert/update/find/delete, typed ordering and conditions. Unsaved IDs remain nullable. Unknown declared query fields fail compilation. Do not expand into the deferred association/eager-loading framework.
- [x] Add typed form inputs over the existing bounded parser. Writable fields are an explicit declaration; unknown/duplicate/missing/invalid inputs produce usable 422 errors while retaining submitted text. Input typing never implies authorization.
- [x] Add resource routes/helpers and template/controller conveniences needed by the generated app, preserving compile-time errors and the explicit trusted-HTML boundary.
- [x] Verify real PostgreSQL behavior, source-level invalid-field fixtures, missing-record behavior, and SQL parameterization. Use restricted runtime and separate migration roles.

Evidence and API details: [typed application APIs](../../research/typed-application-apis.md). Luna workers hit their account usage limit; root continued these tasks locally. Independent review is still pending and the workflow will not be described as reviewed until it happens.

## 2. Managed launcher and project configuration

- [x] Turn the pinned provider experiment into a resumable toolchain installer component, retaining isolated mise state, exact artifact verification and native dependency closure. State the SDK/platform prerequisites and verify a fresh prefix. Do not claim a clean machine from the existing host.
- [ ] Persist framework/toolchain versions outside temporary directories. Rebuild executables against the installed prefix and validate their actual linked libraries.
- [x] Define and validate `.caramel-version`, `config/environment.yml` and local ignored secrets. PostgreSQL major and domain suffix are versioned metadata; credentials remain local. Cloned projects regenerate secrets.
- [ ] Install the launchers and Latte menu app, register the user daemon and complete the reviewed system integration. A failed DNS/trust setup produces an actionable failure before opening a browser.

Toolchain component evidence: [installer checks and limits](../../research/toolchain-installer.md). Fresh-prefix installation, deliberate interruption/resumption, native linking, offline reuse and managed PostgreSQL checks pass; full consumer installation, clean-machine proof and independent review remain pending.

## 3. Frappé command skeleton and application creation

- [x] Implement consistent help/exit codes and command suggestions. Implemented project commands compile in application context; user arguments are argv values, never shell interpolation. Custom `run` commands remain in section 4.
- [x] `new NAME` preflights the complete target, refuses a nonempty directory, creates the documented structure and styled homepage, installs the exact dependency lock, registers/provisions through Latte, and writes local secrets privately.
- [x] `setup` restores a clone without silently updating dependency versions or mutating application schema. Interrupted operations resume safely and preserve user edits.
- [x] Implement services/sites/open/doctor through the same Latte state. Doctor reads and explains compiler, lockfile, PostgreSQL, DNS, proxy and trust problems without repairing them silently.

## 4. Generators and database commands

- [x] Resource generation creates the actual typed model, input, controller, full CRUD views/shared form, routes, migration and meaningful behavior specs. Generate all files before writing; any conflict leaves the project unchanged.
- [ ] Model/controller/migration/command generators share the documented grammar and clear scope. Do not overwrite edited files on a repeated invocation.
- [x] Implement migrate/seed/routes and isolated single-process test execution. Migrations are explicit; seed never resets. The spec runner verifies the exact Latte-owned environment/database identity and refuses development or production.
- [ ] Implement custom `run` commands and parallel spec worker isolation.
- [ ] Add explicit dependency add/update workflows via Shards, show lockfile changes and reject incompatible framework/toolchain metadata.

Generated-project evidence and limitations: [Frappé workflow](../../research/frappe-workflow.md). The actual CLI creates and restores projects, generates Book and mixed-scalar Person CRUD, migrates, and passes generated request specs against separate PostgreSQL databases. Clone and failed-dependency recovery checks pass. Real browser interaction and independent review remain pending.

## 5. Development loop

- [x] `dev` starts or repairs only the managed services it needs, compiles the application, starts it on a private site socket and registers the ready upstream before opening its stable HTTPS URL.
- [x] Watch Crystal/ECR changes with debounce and replace the application only after successful compilation/readiness. Show a same-origin build-error page while source is broken, then recover automatically after the edit is corrected.
- [x] Serve static CSS/JS updates without Crystal compilation. Add same-origin authenticated refresh, no external CDN or frontend package manager.
- [x] Terminal shutdown removes only this dev session's process/route state; shared services and other projects remain usable. Stale process/socket recovery checks ownership.
- [ ] Propagate running/build-error/stopped project state to CLI and menu, and add development runtime exception pages with production exclusion.
- [ ] Measure representative warm/cold builds and static/source refresh, recording actual distributions rather than asserting the proposed timing targets.

Development implementation evidence: [watcher and process ownership](../../research/frappe-development.md). Private-fixture HTTPS tests pass for two concurrent generated apps, source/asset recovery, pending migrations, cached restart and terminal death cleanup. Browser execution, normal system trust, runtime diagnostics, UI state and timing acceptance remain open.

## 6. Generated-app acceptance and next gates

- [ ] Create Bookshelf using `frappe new`, generate Book with `title:string author:string`, run migrate, and exercise browser CRUD through `.caramel` HTTPS.
- [ ] Verify invalid submissions, escaping, CSRF, htmx 4 navigation/422/history/focus and JavaScript-disabled forms in the browser; fix generated output, not only the reference fixture.
- [ ] Clone/setup a second project and prove separate origins, roles, databases, spec isolation and simultaneous dev sessions.
- [ ] Independently review and commit this workflow, with executable documentation matching help.
- [ ] Continue with complete `frappe add auth` and Linux/musl production artifact plans. The overall goal remains active until auth, deployment and installation acceptance are verified.
