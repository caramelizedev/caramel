# Caramel Runtime Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build reusable, tested Crystal web primitives and a PostgreSQL-backed Bookshelf reference application, ready for Frappé generation and Latte hosting.

**Architecture:** Framework code lives in `src/caramel/`; the reference application consumes it as a normal local shard. HTTP responses, escaped views, allowlisted forms, database access, and migrations have separate interfaces. Production browser origins require HTTPS; integration tests can call the HTTP handler directly without weakening production checks.

**Tech Stack:** Crystal 1.21, crystal-pg/crystal-db pinned after source audit, PostgreSQL 18, compiled escaped ECR templates, vendored htmx 4.0.0.

---

## Delivery map

This plan implements the runtime milestone only. The full experience remains tracked below; finishing this plan does not finish Caramel.

- [x] Native toolchain feasibility and isolated mise prototype (existing committed milestone).
- [x] Runtime, PostgreSQL persistence, safe SSR/forms, Bookshelf reference CRUD (browser acceptance remains tracked below).
- [ ] Latte managed database roles/credentials, HTTPS/DNS, registry/supervisor and menu-bar UI.
- [ ] Frappé installer/new/setup/dev/doctor, commands and safe generators, rebuild/error workflow.
- [ ] Optional complete authentication and local mailbox.
- [ ] Native production build/deployment, verified Linux/musl artifact and complete end-to-end acceptance.

## Task 1: Contributor build entry point

Files: `scripts/crystal`, `scripts/shards`, `shard.yml`, `.gitignore`.

- [x] Add a contributor launcher accepting `CARAMEL_TOOLCHAIN_ROOT` (the verified experiment installation), preserving caller CWD. Select compiler, Shards, pkg-config and dedicated OpenSSL paths; never add PostgreSQL libraries to linker paths. A system Crystal remains usable when the root is absent.
- [x] Run `CARAMEL_TOOLCHAIN_ROOT=/private/tmp/caramel-probe.8HlVnW scripts/crystal --version`; expect Crystal 1.21.0. Run existing Python harness tests; expect all five to pass.

## Task 2: Escaped compiled views

Files: `src/caramel/html.cr`, `src/caramel/view.cr`, `src/caramel/view/compiler.cr`, `spec/caramel/view_spec.cr`, `spec/fixtures/views/`.

Public contract:

```crystal
Caramel::HTML.escape(%q(<script>"&')) # escapes all five HTML syntax characters
Caramel::HTML::Safe.new("<strong>Trusted helper output</strong>")
Caramel::View.render("spec/fixtures/views/example.html.ecr") # String; accesses typed local variables
```

- [x] Write failing specs proving expression escaping, trusted helper output exactly once, control-flow loops and typed local access.
- [x] Implement a compile-time ECR processor that emits escaped writes for expressions, literal writes for template source, and permits raw HTML only through the explicit Safe type. Preserve compiler diagnostics for template errors. Document that escaping applies to HTML text/quoted attributes, not script/CSS/URL policy.
- [x] Run `scripts/crystal spec spec/caramel/view_spec.cr`; expect all assertions passing. Compile an invalid-local fixture separately; require compiler failure.

## Task 3: HTTP, forms and request safety

Files: `src/caramel/response.cr`, `src/caramel/router.cr`, `src/caramel/form.cr`, `src/caramel/csrf.cr`, `spec/caramel/http_spec.cr`, `spec/caramel/form_spec.cr`.

Public contract: immutable `Response` with status/body/headers; routes match HTTP method and path segments, distinguish 404/405, and accept a typed request context. Form parser accepts one named envelope and explicit field allowlist, rejects duplicate/unknown fields, bounds input size, preserves submitted values for 422. CSRF uses signed random token cookie, Secure/HttpOnly/SameSite and exact configured origin validation, never suffix comparisons or forwarded-header trust. Method overrides are allowlisted and apply only to POST after validation.

- [x] Write failing behavioral specs for route params/405, duplicate fields, unknown fields, oversized payload, missing CSRF, forged token, cross-origin write, and valid same-origin submission.
- [x] Implement primitives and run their focused specs; expect all passing. Include htmx full/partial Vary behavior in response helpers, and local-only redirect validation.

## Task 4: PostgreSQL and explicit migrations

Files: `src/caramel/database.cr`, `src/caramel/migration.cr`, `spec/integration/database_spec.cr`, `scripts/integration`.

- [x] Pin audited pg/db releases in `shard.yml`/`shard.lock`; restore with locked Shards.
- [x] Write integration specs exercising parameter binding with SQL-looking input, transactional/idempotent migrations, rollback on failure, and separate application/spec databases. The test runner provisions only a new owned disposable cluster and never resets an external database.
- [x] Implement pool-bounded database wrapper, safe connection policy (verified TLS for TCP, private Unix socket for managed local DB), migration table/advisory lock, and pending migration reporting.
- [x] Exercise actual driver trusted/untrusted/wrong-host TLS handshakes and record findings. Run all integration specs against managed PostgreSQL 18.

## Task 5: Bookshelf vertical slice

Files: `examples/bookshelf/{app,config,db,src,spec,public}`, vendored htmx asset/license/digest, root `README.md`.

- [x] Add request specs for create/list/show/edit/update/delete, blank-title 422 retention, CSRF rejection, escaped persisted XSS, htmx partial/full behavior and source-file non-disclosure.
- [x] Implement a styled accessible complete reference resource using only the reusable framework contracts. Use explicit migrations and ordinary progressive-enhancement forms. No app-specific framework behavior.
- [x] Run Crystal/Python checks and real named-HTTPS smoke tests; record compile timings and update current-state documentation.
- [ ] Run actual browser interaction/history/focus/mobile checks through the managed Latte origin after system DNS/trust is installed. Request-level tests and the test-CA curl smoke do not substitute for this gate.
- [x] Independent specification review, then quality review; resolve findings, rerun affected checks and commit the verified milestone.
