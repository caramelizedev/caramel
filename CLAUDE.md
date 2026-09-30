# Caramel

A Crystal framework and its tools: Caramel core, SugarORM, Cold Brew, Corretto, the Frappé CLI and Latte.

- `CONTRIBUTING.md` has the checks, the style, the commit format and the release steps. Read it before changing code.
- Decisions live in `docs/decisions`: read the one that governs a change, and record a new one when a change needs it.
- The design is `docs/rfc.md`.

## Style

Code reads as short sentences, one thought each (RFC-0008, and the Style section of `CONTRIBUTING.md`).

- **Line length.** Every line you add holds at most 100 characters, and most are far shorter.
- **Listed files.** `.ameba.yml` lists older files under `Layout/LineLength`. Add no long line to them. When you rewrite a listed file's long lines, remove it from the list.
- **Stacking.** Put a long signature or call one argument per line, and build records with named arguments.
- **Early returns.** Use guard clauses: `return … if …`, `value = … || return`.
- **Named steps.** Use small private methods named for what they do, and constants for tables and messages. Name headers, bodies and expected values as locals instead of nesting them.
- **Multi-line text** is a heredoc: JSON, SQL, `.env` files and expected output.
- **Specs** test one concern per example, name their inputs, and share setup through small helpers.
- **No service nouns** (`…Service`, `…Manager`, `…Factory`, …): put the verb on its subject.
- **Disables.** An `# ameba:disable Rule -- reason` goes on its own line above the code and names its reason.

## Checks

- **On macOS**, `scripts/check lint` lints the framework, and `scripts/check all` runs everything. The scripts need the managed toolchain from `scripts/install-toolchain`.
- **In a Claude Code on the web session (Linux)**, `.claude/hooks/session-start.sh` installs Crystal 1.21.1, the shards and `bin/frappe-lint`. `scripts/crystal` and `scripts/check` do not run there, so use the plain tools:
  - `bin/frappe-lint` from the repository root lints with `.ameba.yml`;
  - `crystal tool format --check FILES…` checks layout;
  - `crystal spec PATHS…` runs specs.
- Say which checks you could not run, such as the macOS-only ones.

## Commits

- Conventional Commits: `type(scope): subject`, such as `fix(frappe): …`.
- Upgrade notes that a user needs go under `## Unreleased` in `CHANGELOG.md`.
