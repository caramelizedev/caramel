# ADR 0014: One source directory per product under the `caramel` shard

Date: 2026-09-27

Status: accepted.

## Context

The repository is the shard `caramel`. Crystal resolves `require "caramel"` to `src/caramel.cr`, and applications vendor the framework and require it by that name. The CLI is `frappe` (ADR 0013). Latte ships a native macOS menu app and installers, and build output is git-ignored.

## Decision

- Each product owns a top-level source directory named after it:
  - `src/caramel/` for Core;
  - `src/sugar_orm/` for SugarORM;
  - `src/latte/` for Latte;
  - `src/frappe/` for Frappé.
- Cold Brew lives in `src/caramel/cold_brew/`, `cache.cr` and `sse.cr`, because `require "caramel"` loads it into every application.
- Corretto lives in `src/caramel/corretto/`, reached by `require "caramel/corretto"` from specs only.
- `docs/decisions/` holds the ADRs; `docs/` holds nothing else.
- `bin/` is build output from `scripts/build-*`: `frappe`, `latte`, `latte-port-relay` and `Latte.app`.

## Reasons

- Product-named directories match what applications and agents type (`require "caramel"`, `SugarORM::…`, `frappe`, `latte`).
- Keeping Cold Brew under the `caramel` require means the job queue, PubSub and cache ship in every application binary, because one machine is enough.
