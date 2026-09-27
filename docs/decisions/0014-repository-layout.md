# ADR 0014: One source directory per product under the `caramel` shard

Date: 2026-09-27

Status: accepted. Amends [the RFC's Section 5 blueprint](../rfc.md).

## Context

Section 5 sketched this layout:

- `ARCHITECTURE.md`;
- committed `bin/caramel`, `bin/latte` and `bin/roast`;
- a `src/core`, `src/orm`, `src/concurrency`, `src/dx`, `src/agent`, `src/testing` and `src/ops` tree;
- `packages/`.

The repository grew as the shard `caramel`. Crystal resolves `require "caramel"` to `src/caramel.cr`. Applications vendor the framework and require it by that name. The CLI is `frappe` (ADR 0013). Latte ships a native macOS menu app and installers, and build output is git-ignored.

## Decision

- Each product owns a top-level source directory named after it:
  - `src/caramel/` for Core (RFC-0001);
  - `src/sugar_orm/` for SugarORM (RFC-0002);
  - `src/latte/` for Latte (RFC-0004);
  - `src/frappe/` for Frappé (RFC-0005).
- Cold Brew (RFC-0003) lives in `src/caramel/cold_brew/`, `cache.cr` and `sse.cr`, because `require "caramel"` loads it into every application.
- Corretto (RFC-0006) lives in `src/caramel/corretto/`, reached by `require "caramel/corretto"` from specs only.
- `docs/rfc.md` is the architecture document. `docs/decisions/` holds the ADRs that amend it, and `docs/research/rfc-implementation-status.md` holds the status matrix.
- `bin/` is build output from `scripts/build-*`: `frappe`, `latte`, `latte-port-relay` and `Latte.app`.
- Section 5 lists what exists. RFC-0007's `bin/roast`, `src/ops` and `packages`, and RFC-0008's unit extensions, are marked planned.

## Reasons

- Product-named directories match the product map in RFC §3, and they match what applications and agents type (`require "caramel"`, `SugarORM::…`, `frappe`, `latte`).
- Keeping Cold Brew under the `caramel` require means the job queue, PubSub and cache ship in every application binary, which Manifesto 1 (the single machine is sufficient) intends.

Principles followed:

- Manifesto 6: stateless tools that agents can discover.
- Manifesto 8: no ceremonial indirection.

## Verification

- `docs/research/rfc-implementation-status.md` maps each Section 5 entry to its files.
- The final audit checks that every listed path exists.
