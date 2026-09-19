# Caramel Managed Toolchain Feasibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Establish an evidence-backed tool distribution choice for Caramel on Apple Silicon before building its consumer installer.

**Architecture:** Evaluate mise behind the toolchain boundary using isolated configuration and storage. Frappé remains the user interface, Shards manages application dependencies, and Latte owns project/service/data lifecycle. This bounded feasibility milestone produces installation evidence and a decision; the application and installer receive separate implementation plans after the evidence is available.

**Tech Stack:** Crystal, Shards, PostgreSQL, Caddy, mise; macOS ARM64 initially.

---

## Execution status — 2026-09-19

The scoped local experiment is complete; see [ADR 0001](../../decisions/0001-managed-toolchain-provider.md), the [installation report](../../research/toolchain-installation.md), and the preserved evidence. Mise is accepted for contributor/prototype tooling. Clean-machine consumer acceptance remains unverified. Checkmarks below mean the investigation was performed and its pass/fail result recorded, not that every product acceptance gate passed.

## Context and scope

Read `docs/superpowers/specs/2026-09-19-caramel-developer-experience-design.md`, especially sections 8–9. Crystal, PostgreSQL, bundled htmx 4, trusted HTTPS, and named `.caramel` domains remain product requirements regardless of mise's outcome.

The repository currently contains design documentation only. The development machine already exposes a PostgreSQL 17 client from Laravel Herd. Crystal, Shards, Caddy, and mise were not on PATH during the initial inspection. This machine is therefore useful for coexistence checks but cannot establish clean-machine installation quality. Docker daemon access was not established; do not assume Docker is available for the evaluation.

No system DNS, trusted roots, privileged listeners, global shell configuration, or existing database data needs changing in this milestone. Downloaded executables and dependency installers must be inspected and isolated before execution. If clean macOS infrastructure is unavailable, report that acceptance gate as unverified.

## Evidence files

Create these during execution:

| File | Responsibility |
| --- | --- |
| `docs/research/toolchain-artifacts.md` | Exact tool/backend versions, platform assets, integrity/provenance, native dependency requirements, licenses |
| `docs/research/toolchain-installation.md` | Reproducible commands, machine prerequisites, measured timings, failure/retry and isolation results |
| `docs/decisions/0001-managed-toolchain-provider.md` | Adopt/reject/partially adopt mise, with evidence and remaining gates |

Keep downloaded artifacts, working clusters, credentials, and caches in a dedicated temporary evaluation directory outside the repository. Evidence records commands and redacted output, never passwords or private keys.

## Task 1: Inspect artifact availability

- [x] Review the current [mise registry](https://mise.jdx.dev/registry.html), [lockfile guarantees](https://mise.jdx.dev/dev-tools/mise-lock.html), and [installation documentation](https://mise.jdx.dev/installing-mise.html). Record the exact mise release selected for evaluation; do not use a floating `latest` version in the recorded reproduction.
- [x] Inspect Crystal's GitHub backend and the Crystal plugin alternatives. Record Apple Silicon archive availability, included Shards version, linker/compiler requirements, and linked native libraries. A downloaded compiler executable alone does not satisfy this task.
- [x] Inspect Caddy's aqua backend. Record its exact release, artifact digest, supported architecture, verification mechanism, and runtime dependencies.
- [x] Compare PostgreSQL's conda backend with the vfox plugin. Record whether each provides prebuilt ARM64 binaries, its transitive runtime libraries, and any automatic cluster initialization. The vfox plugin documents source compilation and `POSTGRES_SKIP_INITDB=1`; verify current behavior before executing it.
- [x] Write `docs/research/toolchain-artifacts.md` with one row per evaluated backend. Mark unavailable or unverified fields explicitly. Select candidates for installation only after identifying their side effects and prerequisites.

Expected result: a reproducible candidate set with exact versions and explicit prerequisite costs. Reject source compilation as the default consumer PostgreSQL setup; it may remain a contributor option.

## Task 2: Prove installation and command execution

Depends on Task 1's candidate selection.

- [x] Create a dedicated temporary directory. Use the selected mise release's documented configuration/data/cache overrides and verify the resolved paths before installation. Record all overrides and working directories in `docs/research/toolchain-installation.md`.
- [x] Install the pinned mise binary after verifying its published integrity/provenance. Use only reviewed tool configuration with explicit backends. Record whether each backend's lock entry includes an artifact URL and checksum.
- [x] Install the candidate tools into the isolated directories. Measure elapsed time and downloaded bytes; list any required Xcode tools or system packages. Do not silently install Homebrew prerequisites into the user's environment.
- [x] Through `mise exec`, run `crystal --version`, `shards --version`, `caddy version`, `postgres --version`, and `initdb --version`. Record the complete invocation with the selected exact versions and compare every result with the candidate set. No shell activation should be required.
- [x] Inspect downloaded native executables with `file` and `otool -L`. Record any linkage to Homebrew, Herd, or libraries outside the selected distribution and OS. Such dependencies must be declared or bundled before claiming consumer readiness.
- [x] Repeat the locked installation with the populated cache. Disconnect network access for a separate cached execution check. Record separately whether cached tool execution and cached reinstallation succeed; do not imply one proves the other.
- [x] Interrupt one installation in the disposable directory, retry it, and check that execution cannot select a partially installed executable. Preserve the exact command, observed failure, and recovery result.

Expected result: documented pass/fail evidence for installation, dependency closure, exact-version execution, warm cache behavior, and recovery. A successful contributor installation is useful even if consumer prerequisites fail.

## Task 3: Verify ownership and coexistence

Depends on Task 2. No production service or existing cluster is used.

- [x] Confirm tool installation did not initialize a PostgreSQL cluster in its tool directory. If the backend does so by default, repeat using its documented suppression setting and record the result.
- [x] Create a disposable database cluster in a separate data directory using `initdb`; start it through `pg_ctl` using a private Unix socket directory and no TCP listeners. Query `SHOW data_directory`, `SHOW server_version`, and `SELECT 1` using that distribution's `psql`.
- [x] Stop it with `pg_ctl` and restart it, then repeat the queries. Expected: the same data directory and version, successful query, and no dependency on a mise-managed daemon. Clean up only this disposable cluster after stopping it.
- [x] Compare PATH and shell configuration before/after the experiment and confirm the existing Herd client remains selected outside the isolated invocation.
- [x] Verify two exact tool versions can coexist and that selecting one does not remove the other. Prefer two Crystal patch releases with available artifacts; record both exact versions and `crystal --version` results.
- [x] Audit inherited mise configuration and hooks. Document how a future Frappé adapter will restrict internal setup to Caramel-owned configuration without automatically trusting arbitrary project tasks.

Expected result: mise can supply binaries while Latte independently owns persistent state and service lifecycle. Existing tools and services remain functional.

## Task 4: Record the decision and subsequent delivery order

- [x] Write `docs/decisions/0001-managed-toolchain-provider.md`. Choose separately for contributor tooling and the consumer installer: adopt mise, adopt it with Caramel-provided binary bundles, or use another distribution mechanism. Link evidence for each choice.
- [ ] Run the chosen candidate on a clean Apple Silicon macOS environment without Herd/Homebrew. If unavailable, explicitly leave consumer adoption provisional. Enumerate every required prerequisite and measure first installation; no invented timing targets or results.
- [x] Record the supported source of truth for versions. If mise configuration is generated from Caramel's manifest, specify which file is authored and which is derived. Avoid two editable version declarations.
- [x] Update design section 8.3 with the decision and its limits. Review the diff with `git diff --check` and `git diff -- docs`; commit only the reviewed documentation and reproducible non-secret configuration, if any.

This milestone does not implement the remaining design. Subsequent delivery order:

1. **Bookshelf vertical slice:** native Crystal HTTP app, escaped server templates, locally bundled htmx 4, PostgreSQL reads/writes, explicit migration, safe form handling. Measure cold and edit/rebuild times. Verify database certificate-chain and hostname checks on the chosen Crystal driver.
2. **Latte environment:** managed PostgreSQL lifecycle, project registry, scoped DNS, Caddy/private trust, `https://bookshelf.caramel`, restart/build-error behavior, coexistence with Herd, basic menu-bar controls. Plan privileged setup and recovery explicitly.
3. **Frappé workflow:** make `new`, `setup`, `dev`, `doctor`, and a resource generator deliver the verified slice from a clean installation. Check cloned-project restoration and multiple simultaneous projects.
4. **Optional auth and deployment:** one-command auth with conflict/retry behavior, then a production deployment using the same database/schema assumptions and a verified native artifact.

Each receives its own executable implementation plan after the preceding integration gate passes. The first public demonstration should show the full create/edit/browser loop; a working tool installer alone is not the product.

## Agent allocation

The user has selected agent-driven building. Use Luna at its highest supported reasoning effort (`max` in this environment; `ultra` is unavailable). Artifact inspection can be divided between compiler/HTTPS and database backends with disjoint evidence sections. Installation, shared configuration changes, and lifecycle tests run sequentially under one owner. The orchestrator reviews evidence, resolves the provider decision, and reviews integration before dispatching framework work.
