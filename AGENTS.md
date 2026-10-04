# Caramel

A Crystal framework and its tools: Caramel core, SugarORM, Cold Brew, Corretto, the
Frappé CLI and Latte.

These instructions are for changing the framework. In an application this file sits
under `lib/caramel`: ignore it there and follow the application's own AGENTS.md.

- Read `CONTRIBUTING.md` before changing code: checks, style, writing, commits and releases.
- Decisions live in `docs/decisions`. Read the one that governs a change; a change that
  alters a decision edits that ADR in the same commit.
- Status, measurements, investigations and history never go in this repository
  (CONTRIBUTING.md, Writing).
- History, research and measurements live in
  [caramel-notes](https://github.com/caramelizedev/caramel-notes). Before investigating a
  problem, read its `index.md`, at `../caramel-notes` when it is checked out beside this
  repository; put new findings in its `inbox/`, as its AGENTS.md describes.

## Checks

- **On macOS**, `scripts/check lint` lints the framework, and `scripts/check all` runs everything. The scripts need the managed toolchain from `scripts/install-toolchain`.
- **In a Claude Code on the web session (Linux)**, `.claude/hooks/session-start.sh` installs the pinned Crystal, the shards and `bin/frappe-lint`. `scripts/crystal` and `scripts/check` do not run there, so use the plain tools:
  - `bin/frappe-lint` from the repository root lints with `.ameba.yml`;
  - `crystal tool format --check FILES…` checks layout;
  - `crystal spec PATHS…` runs specs.
- Say which checks you could not run, such as the macOS-only ones.
