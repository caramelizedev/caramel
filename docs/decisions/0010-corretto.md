# ADR 0010: Corretto runs each example against the real application and a real database, and rolls it back

Date: 2026-09-27

Status: accepted.

## Context

Corretto needs subcutaneous sessions, a ban on mocks, per-worker databases, per-example rollback, synchronous queue drains and wire-level fakes. Two constraints shape it: Crystal's shared compiler cache makes parallel `crystal spec` processes overwrite each other's output, and a least-privileged runtime role cannot run DDL.

Raw HTML substring assertions couple specs to quote style, attribute order and escaping spelling, and let unrelated elements satisfy a check. Rendering an expected view through the same code would hide renderer defects.

## Decision

1. **Each worker is its own compiled spec binary on its own clone of the migrated spec database.** `frappe corretto` migrates the spec database once, and Latte clones one database per worker from it.
2. **Runs in one project serialize on a whole-run lock.** A second run waits for the first.
3. **Every example runs in a transaction that is rolled back, and its requests run in-process on the same connection.**
4. **A catalog fingerprint finds DDL that escaped the transaction, and the worker database is then reset from the migrated template.** An example tagged as changing the catalog runs outside the transaction on a migration-role connection and always resets.
5. **A worker starts from a cleared environment, and the application's test settings come from a committed file.**
6. **Matchers assert against observable egress and state.**
7. **HTML expectations are Blueprint-shaped requirements matched against parsed elements.** The expected nodes are independent data, never view invocations or rerendered HTML.
8. **Lexbor parses the HTML, as a development dependency required only through Corretto.** An `hx-partial` envelope is parsed as htmx reads it.
9. **Behavioral specs assert decoded elements; byte tests and browser checks keep what only they prove.** Exact byte tests remain for serialization and escaping, and browser checks for htmx morphing.
10. **Third parties are faked at the wire, through a proxy that the framework's one outbound HTTP client is pointed at.** A stub answers real request bytes, and a request no stub matches fails. A direct call refuses the host's own network and connects to the address it vetted.
11. **Mocks do not compile and do not run.** Loading a mocking library is a compile error, and `frappe corretto` refuses to run a spec file that calls a mocking API.
12. **Specs drain queues synchronously, and no worker runs in the test environment.** The drain rule is in [ADR 0009](0009-cold-brew.md).
13. **A full passing run fails unless an example that ran names every requirement id the application declares.** A run of chosen paths checks nothing.
14. **Property cases run any typed class method on generated arguments, and Corretto names no library.** A type that Corretto cannot draw supplies its own generator as a class method, as a library does for its types ([ADR 0035](sweettalk/0035-reads-and-rules.md)). An exception is marked as outside the domain at run time, and a case that raises it is skipped.
15. **A session is a signed cookie the browser holds, with nothing held server-side, and a spec signs in by writing it.** The current application secret signs, and it and each previous secret verify.

## Reasons

- Running requests in-process on the example's own transaction lets one rollback undo the example's writes, its requests' writes and its jobs' writes. No global cleanup code is needed.
- A catalog fingerprint detects exactly the case a rollback cannot undo, so resets happen only when needed. Tagged examples use a migration-role connection so that they may run DDL.
- Separate compiled spec binaries are the only reliable way to run workers in parallel: they avoid the compiler-cache clash.
- Every run uses the same workers, binaries and Latte databases, so two runs in one project cannot overlap. Rejected: pid-derived worker names, which would break the fixed worker range and Latte's role limit.
- A proxy the framework client already knows about intercepts real HTTP bytes without monkey-patching any Crystal method. An unmatched request fails, so no test reaches the real network.
- Connecting to the vetted address means a user-supplied URL cannot reach the host's own network and a DNS answer cannot change between the check and the connection.
- Deriving keys from the current secret and from each previous one lets a secret rotate without ending every session and open form at once.
- No tautological mocks: specs test subcutaneous behaviour against real PostgreSQL branches and real morphed HTML, and read as ingress, state and egress.
- A property runner that names no library runs any typed class method, and a library gives its own types their generators, so Corretto depends on none of them.
- A generator is a class method on its type because the check that refuses an undrawable argument runs at compile time, and it can see a method. Rejected: a generator registered at run time, which would be refused only in the example.
- An exception is marked as outside the domain at run time because nothing at compile time depends on it.
- Decoded elements make specs independent of quote style, attribute order and escaping spelling.
- Blueprint's finite vocabulary catches misspellings at compile time, and requirements read like the project's views.
- Rejected: rendering a second Blueprint tree, because shared escaping defects would pass.
- Rejected: raw text helpers, because they cannot establish ancestry.
- Rejected: a homegrown HTML parser, because it repeats mature HTML5 parsing machinery.
- Rejected: browser-only assertions, because they add process overhead to request specs; browser tests stay for interactions.
- Rejected: CSS as a second complete public DSL; it serves only to scope an expectation.
