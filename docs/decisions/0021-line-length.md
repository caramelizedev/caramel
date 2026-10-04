# ADR 0021: Line length for the framework

Date: 2026-09-29

Status: accepted. Amends [ADR 0017](0017-formatting-and-linting.md) decisions 4 and 6 for the framework's own code.

## Context

- The formatter owns indentation and spacing but never breaks a line, so long lines accumulate: a call with six arguments, a hash and a block on one line reads as a run-on sentence, and its diff hides which argument changed.
- Generated applications grow lines with their fields, which is why ADR 0017 left `Layout/LineLength` off for them. The framework's code is written by hand.

## Decision

1. **The framework's `.ameba.yml` enables `Layout/LineLength` at 100 characters**, so `scripts/check lint` enforces it. Ameba counts characters, not bytes.
2. **No file is exempt.** The rule excludes no file, and no file may disable it with an inline directive.
3. **Applications are unchanged.** Applications keep ADR 0017's rule set. `templates/application/.ameba.yml` keeps the rule off, because generated resources write lines that grow with their fields.
4. **What a linter cannot check is written down**: in the Style section of `CONTRIBUTING.md` for people and agents (`AGENTS.md` points agents there). This covers named steps, early returns, stacked arguments, heredocs for multi-line text, and specs that name their inputs.
5. **`scripts/check lint` proves the limit is on and exempts nothing.**
   - Under the framework's configuration, a 101-character line must be reported and a 100-character line must not.
   - The rule must have no `Excluded` key.
   - No linted file may carry an `# ameba:disable Layout/LineLength` (or `Layout`) directive.

## Reasons

- A limit that no tool checks drifts. The limit belongs in the rule set that already runs in `scripts/check lint` and before every release.
- 100 characters leaves room for lines that a shorter limit would split for no gain, such as a spec's description or a row of an aligned table. The Style section asks for lines that read as one thought, which are usually far shorter.
- Rejected: a per-file `Excluded` list, because a listed file can still gain a long line and an exception, once allowed, invites the next. With none, the proof refuses any new one, in the configuration or inline.
- Rewrites that enforce the limit keep the strings the code emits or compares byte-identical, so the change is layout only.
