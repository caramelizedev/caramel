# ADR 0010: Corretto runs every example in a rolled-back savepoint on a Latte worker database, with in-process requests and wire-level fakes

Date: 2026-09-27

Status: accepted. Amends [RFC-0006](../rfc.md) §2.1–2.4 and §3, and the RFC-0005 command list (`frappe corretto` replaces `frappe test`).

## Context

RFC-0006 specifies what Corretto must do:

- subcutaneous sessions with `sign_in`, custom matchers, and a ban on mocks;
- three isolation tiers: per-worker branches, per-example savepoints, and catalog resets;
- synchronous queue drains;
- wire-level fakes through a local proxy;
- `--concurrency`.

Several pieces were missing before this work: Caramel had no session to sign in to, no outbound HTTP client whose traffic a proxy could intercept, and no way to run tests in parallel. Two constraints also shaped the design. Crystal's shared compiler cache makes parallel `crystal spec` processes overwrite each other's output. And a least-privileged runtime role cannot run DDL.

## Decision

1. **Sessions and sign-in.** `Caramel::Session` is an HMAC-SHA256 signed `__Host-caramel_session` cookie (HttpOnly, Secure, SameSite=Lax, at most 4 KB, verified in constant time). Its key is derived from the application secret. Actions read and write `session`, and `sign_out` clears it. `client.sign_in(user)` writes `user_id` into the client's session cookie.
2. **In-process client.** `Corretto.session { |client, db| … }` yields a client that drives `Caramel::Application#handle` directly. It keeps a cookie jar, attaches CSRF, `Origin` and `Host` automatically, and follows redirects. It also yields the example's database connection.
   - A request's body is URL-encoded `params:`; `params:` with `files:` of `Corretto::Upload` values, which is multipart; `json:`; or a raw `body:` typed by a `Content-Type` header.
   - `Corretto.tmpdir` is a private directory for the files an example writes, removed when the example ends, because the rollback does not undo filesystem writes.
3. **Matchers** assert against observable egress and state: `have_status`, `render_partial(target, swap:)`, `redirect_to`, `have_header`, `render_page` and `have_row(Schema, **conditions)`. `have_row` is a macro, so unknown fields fail compilation.
4. **Isolation.**
   - **Tier 2.** A global `Spec.around_each` opens a transaction and SAVEPOINT on the worker's single connection and binds it with `SugarORM::Repo.bind(transaction)`. The example, including its in-process requests, runs on that connection, and the savepoint is rolled back afterwards.
   - **Tier 3.** At boot Corretto records a catalog fingerprint: a hash of `pg_class`, `pg_attribute`, `pg_index` and `pg_constraint` rows in the public schema. If an example leaves the catalog changed, meaning DDL escaped the transaction, Corretto resets the worker database from the migrated template through Latte and reports which example did it. Examples tagged `catalog` run without the savepoint, on a migration-role connection so that they may run DDL, and always reset afterwards.
   - **Tier 1 and §3.** `frappe corretto [SPEC_PATHS…] [--concurrency=1..8]` migrates the spec database once and asks Latte (`POST|DELETE /v1/sites/:id/test-workers/:n`) to clone one worker database per worker from it, behind the connection guard. It splits spec files round-robin and runs each worker as its own compiled spec binary, which avoids the compiler-cache clash. It prefixes and aggregates output and exit statuses, then drops the workers.
   - `frappe test` is replaced, not aliased.
5. **Drain.** Specs call `Caramel::ColdBrew.drain_queue!(db, "default")` (ADR 0009). No worker fibers run under `CARAMEL_ENV=test`.
6. **Wire fakes.**
   - `Caramel::Outbound` is the framework's outbound HTTP client. It connects directly in production. When `Outbound.proxy` is set, it sends absolute-form HTTP/1.1 requests to that proxy.
   - Corretto starts a local TCP proxy for the suite. `Corretto.stub_wire(url, method:).to_return(status:, fixture:, body:, headers:)` matches real request bytes by method and absolute URL. Unmatched requests get a 502 `Unstubbed outbound request: METHOD URL`, so no test reaches the real network.
   - `Corretto.wire_requests` records traffic. Stubs reset after each example.
7. **No mocks.** Loading a mocking library is a compile error. `frappe corretto` also scans spec files for mocking APIs (`allow(`, `receive(`, `double(`, `instance_double(`, `.stub(`, `mock(`) and refuses to run, naming the file and line.
8. **Application test settings.** Spec workers start from a cleared environment and never receive the development `.env`. Settings the application reads itself come from the committed `.env.test`, in the `.env` format, which Corretto merges under its own keys. It refuses keys it or the toolchain supplies: `APP_ORIGIN`, `APP_SECRET`, `DATABASE_URL`, `MIGRATION_DATABASE_URL`, `PATH`, `HOME` and the `SPEC_`, `CARAMEL_`, `CORRETTO_`, `CRYSTAL_`, `LD_` and `DYLD_` prefixes.
9. **Connection limits.** Parallel and catalog examples need more connections, so Latte raises the spec migration role's limit to 8 and the runtime role's limit to 24. The runtime limit also covers Cold Brew's pool and listener.

## Reasons

- Running requests in-process on the example's own transaction lets one rollback undo the example's writes, its requests' writes and its jobs' writes. No global cleanup code is needed.
- A catalog fingerprint detects exactly the un-rollbackable case, so resets happen only when needed.
- Separate compiled spec binaries are the only reliable way to run workers in parallel with Crystal 1.21.
- A proxy the framework client already knows about intercepts real HTTP bytes without monkey-patching any Crystal method.

Principles followed:

- Manifesto 5: no tautological mocks; test subcutaneous behaviour against real PostgreSQL branches and real morphed HTML.
- Manifesto 4: data integrity.
- RFC-0008 §2.5: specs read as ingress, state and egress.

## Verification

- `spec/caramel/session_spec.cr` covers tampering, oversize input and re-issue.
- `spec/corretto/*_spec.cr` covers the client, the matchers against real responses, wire request parsing and the mocking scan.
- `spec/integration/corretto_spec.cr` (`scripts/check integration`) covers savepoint rollback with a bound Repo, fingerprint detection and reset, and wire stubs through a real `Caramel::Outbound` request.
- `scripts/check latte-postgres` covers the test-worker endpoint.
- `scripts/check frappe-project` covers these, and runs the generated specs through `frappe corretto --concurrency=2`:
  - savepoint isolation between examples;
  - a leaked-DDL reset;
  - wire isolation;
  - a Cold Brew job drained synchronously;
  - refusal of a planted `allow(`.
- The sub-millisecond per-example isolation target is a performance claim and is deferred.
