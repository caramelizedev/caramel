# ADR 0021: Line length for the framework

Date: 2026-09-29

Status: accepted. Amends [ADR 0017](0017-formatting-and-linting.md) decisions 4 and 6 for the framework's own code. Applications keep ADR 0017's rule set.

## Context

- ADR 0017 did not adopt `Layout/LineLength`. Its reason was that a generated resource's lines grow with its fields, and the formatter owns layout.
- The formatter owns indentation and spacing, but it never breaks a line. At `2f666b1`, 191 of the 213 files the framework lints had a line over 100 characters: 2,543 lines in all, the longest 515 characters.
- Reviewing the fixes for the first-user issues showed the cost. A call with six arguments, a hash and a block on one line reads as a run-on sentence, and its diff hides which argument changed. Rewriting that code as short, named steps made it easier to read and to review without changing what it does.
- ADR 0017's reason holds for generated applications, not for the framework, whose code is written by hand.

## Decision

1. **The framework's `.ameba.yml` enables `Layout/LineLength` at 100 characters**, so `scripts/check lint` enforces it. Ameba counts characters, not bytes.
2. **The limit ratchets.** The rule's `Excluded` list names every file that had a longer line when the rule was adopted.
   - New files must pass.
   - A file leaves the list in the change that rewrites its long lines, and no file joins it.
   - `scripts/checks/lint.cr` left the list in this change.
3. **Applications are unchanged.** `templates/application/.ameba.yml` keeps the rule off, because generated resources still write lines that grow with their fields.
4. **What a linter cannot check is written down**: in the Style section of `CONTRIBUTING.md` for people, and in `CLAUDE.md` for agents. This covers named steps, early returns, stacked arguments, heredocs for multi-line text, and specs that name their inputs.
5. **`scripts/check lint` proves the limit is on.** Under the framework's configuration, a 101-character line must be reported and a 100-character line must not.

## Reasons

- A limit that no tool checks drifts. The limit belongs in the rule set that already runs in `scripts/check lint` and before every release.
- 100 characters leaves room for lines that a shorter limit would split for no gain, such as a spec's description or a row of an aligned table. The Style section asks for lines that read as one thought, which are usually far shorter.
- A per-file list is what Ameba's `Excluded` supports. Its weakness is that a listed file can still gain a long line. Review catches that, and each cleaned file loses its exception for good. A line-level baseline would need a Caramel rule and a stored record of every existing long line.
- Rewriting all 191 files at once would bury real changes in the history, and would risk changing behaviour in code no one is working on. Files are cleaned as they are touched.

Principles followed:

- Manifesto 8: code must read like poetry, "structured with natural cadence".
- RFC-0008 §1: conceptual compression, code that reads like concise prose.
- Manifesto 7: a deterministic check that agents run and read.

## Verification

- `scripts/check lint` first proves that `Caramel/ServiceNoun` reports service nouns. It then proves that `Layout/LineLength` reports a 101-character line and not a 100-character one under the framework's configuration. Finally it lints the framework, which must pass.
- The proof was mutation-checked. Raising `MaxLength` to 140 fails it, and so does disabling the rule. A 110-character comment added to a file not on the list fails the framework lint.
