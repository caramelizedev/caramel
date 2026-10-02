# ADR 0013: The CLI is `frappe`; one command table drives it; `frappe check` emits MRDP or RFC-0008 typography

Date: 2026-09-27

Status: accepted. Amends [RFC-0005](../rfc.md) §2.1–2.3 and §3, and the `caramel` command names used in RFC-0004 and RFC-0006.

## Context

RFC-0005 calls the CLI `caramel`, with `caramel check`, `routes [filter]`, `db:branch`, `db:diff`, `corretto` and `agent-manifest`. It defines a Tier-1 `--no-codegen` loop, defers native builds to deployment, and specifies dual-mode diagnostics (ANSI for humans, MRDP for agents) and exit code 1 for invalid input.

The shipped CLI is Frappé (`frappe`). It exited 2 on bad input and had no agent surface. Crystal cannot run an application without building it natively. Frappé also talks to Latte's daemon for service and database side effects.

## Decision

1. **The binary is `frappe`.** Frappé is the product that RFC-0005 describes, and `caramel` names the framework shard that applications depend on. RFC command names become:
   - `frappe check`, `frappe routes [FILTER]`, `frappe db branch create|list|delete`, `frappe db diff --name`, `frappe corretto` and `frappe agent-manifest`;
   - `frappe db branch create`, replacing `caramel latte branch create`;
   - `frappe corretto --concurrency`.
2. **One command table** (`src/frappe/commands.cr`) is the single source for `help`, `COMMAND --help`, argument validation, pinned-release dispatch and `frappe agent-manifest`. Unknown commands and malformed arguments exit **1** with the command's exact one-line syntax and a "Did you mean" suggestion.
3. **Stateless commands.** Every Frappé command is a one-shot process with no session state. Latte's daemon is a service supervisor (ADR 0012), not a JSON-RPC agent protocol. Frappé calls it only to start services, provision sites, branches and test databases, and register upstreams.
4. **`frappe check` is Tier 1.** It runs `crystal build --no-codegen` for the project's main target with the development flags, parses the real compiler output, and classifies each diagnostic as one of `CONTRACT_MISMATCH`, `N_PLUS_ONE`, `UNDEFINED_METHOD`, `UNDEFINED_CONSTANT`, `NO_OVERLOAD`, `SYNTAX` or `COMPILE`.
   - **Mode A** (a TTY, or `--human`) draws RFC-0008 §2.6's box: file and line, the source line, a caret, the message and a Remediation block. It is coloured only on a TTY.
   - **Mode B** (`--agent`, or stdout not a TTY) prints MRDP. The grammar is `ERR <CODE>[:<status>] at <file>:<line>:<col>`, then `NODE`, `MISSING`, `MSG`, `FIX`, `PATCH: INSERT "…" AT|AFTER <line>:<col>`, `SYNTAX`, `SUGGEST`, `OK <command> <summary>`, and exit 0 exactly when there is no `ERR`.
   - For a contract mismatch, the router reports `Contract: file:line:col` from a compile-time `CARAMEL_CONTRACT_LOCATION`. `ERR` points at the action's `contract do`, and `PATCH` inserts the missing field on the next line.
   - `N_PLUS_ONE` patches insert `.preload(:name)` after the query.
   - Usage errors, migration lint refusals (`LINT_<RULE>`) and `db diff` halts (`DIFF_HALT`) use the same MRDP.
5. **Tier 2.** Native builds serve the running application: `frappe dev`, `routes`, `migrate`, `seed`, `corretto` and `db diff`'s headless `schema` binary. Crystal's interpreter cannot serve them yet: the official macOS build that the managed toolchain installs is compiled without it, and the experimental interpreter in other builds, measured on 2026-10-02, started a 22-resource application more slowly than a warm build and failed under a request loop ([local-performance.md](../research/local-performance.md#follow-up-compiler-side-options-2026-10-02)). Until 2026-10-02 this item said that Crystal has no interpreter for whole applications. Deployment builds belong to RFC-0007 and are out of scope. Tier 1 remains the agent's verification loop.
   - Since 2026-09-30, commands share the development build. A command reuses a build of the same inputs: the source signature `frappe dev` hashes, the toolchain, the framework version and the development flags. It takes `frappe dev`'s build, hard-linked into `.caramel/application` so the session's cleanup cannot delete it, or else the previous command's, and builds into `.caramel/application` only when neither matches. `.caramel/build.lock` serializes the application's builds: a command waits while `frappe dev` or another command builds, and `frappe dev` waits for a command's build, so no two builds write the program's compiler cache at once.
6. **`frappe expand FILE:LINE:COL`** prints the plain Crystal that a macro call expands to (RFC-0008 §3's `caramel expand`).

## Reasons

- Naming the CLI after its product keeps the RFC's own product map intact (Frappé is the CLI). It also avoids renaming a shipped binary that every script and template already uses.
- A single table cannot drift from help, validation or the manifest. An agent that reads the manifest gets exactly what the parser accepts.
- PATCH lines that apply mechanically turn a compile error into a one-step repair for an agent. `scripts/check frappe-project` proves this loop.

Principles followed:

- Manifesto 6: stateless POSIX tools with token-dense diagnostics.
- Manifesto 7: sub-second repair loops for agents, clarity for humans.
- RFC-0008 §2.6: artisan terminal typography with remediation.

## Verification

- `spec/frappe/commands_spec.cr` covers the table, syntax, exit codes and the manifest.
- `spec/frappe/diagnostics_spec.cr` covers the parser against 29 captured real compiler outputs, plus the MRDP and ANSI formatting.
- `spec/frappe/cli_spec.cr` covers the CLI surface.
- `scripts/check route-compilation` covers the `Contract:` locations.
- `spec/frappe/build_slot_spec.cr` covers when a kept build is reused: only for its fingerprint, toolchain and mode, with its bytes intact. It also covers a linked build outliving the original.
- `scripts/check frappe-project --dev` asserts that `frappe migrate` beside a running session runs the session's build of the same sources rather than a new one.
- `scripts/check frappe-project`:
  - `agent-manifest` lists every command, and unknown input exits 1 with the syntax;
  - the `routes` filter;
  - a planted contract mismatch whose PATCH, applied mechanically, makes `check` pass;
  - a planted N+1 with the `--human` box;
  - `expand`;
  - `db branch create/list/delete` with a connectable URL.
- `scripts/check schema-diff` covers `DIFF_HALT` and `LINT_*` in MRDP and human form.
- The ~180 ms Tier-1 time, sub-20 ms commands and >70% token savings are performance claims and are deferred.
