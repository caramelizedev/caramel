# ADR 0021: Line length for the framework

Date: 2026-09-29

Status: accepted. Amends [ADR 0017](0017-formatting-and-linting.md) decisions 4 and 6 for the framework's own code. Applications keep ADR 0017's rule set. The exclusion list emptied on 2026-09-30, so no file is exempt.

## Context

- ADR 0017 did not adopt `Layout/LineLength`. Its reason was that a generated resource's lines grow with its fields, and the formatter owns layout.
- The formatter owns indentation and spacing, but it never breaks a line. At `2f666b1`, 191 of the 213 files the framework lints had a line over 100 characters: 2,543 lines in all, the longest 515 characters.
- Reviewing the fixes for the first-user issues showed the cost. A call with six arguments, a hash and a block on one line reads as a run-on sentence, and its diff hides which argument changed. Rewriting that code as short, named steps made it easier to read and to review without changing what it does.
- ADR 0017's reason holds for generated applications, not for the framework, whose code is written by hand.

## Decision

1. **The framework's `.ameba.yml` enables `Layout/LineLength` at 100 characters**, so `scripts/check lint` enforces it. Ameba counts characters, not bytes.
2. **No file is exempt.** The limit started as a ratchet:
   - The rule's `Excluded` list named the 190 files that still had a longer line once `scripts/checks/lint.cr` was rewritten with the rule.
   - Those files were then rewritten one commit per file, each taking its file off the list (caramelizedev/caramel#9–#14 and #16). The list emptied on 2026-09-30.
   - The rule now excludes no file, and no file may disable it with an inline directive.
3. **Applications are unchanged.** `templates/application/.ameba.yml` keeps the rule off, because generated resources still write lines that grow with their fields.
4. **What a linter cannot check is written down**: in the Style section of `CONTRIBUTING.md` for people, and in `CLAUDE.md` for agents. This covers named steps, early returns, stacked arguments, heredocs for multi-line text, and specs that name their inputs.
5. **`scripts/check lint` proves the limit is on and exempts nothing.**
   - Under the framework's configuration, a 101-character line must be reported and a 100-character line must not.
   - The rule must have no `Excluded` key.
   - No linted file may carry an `# ameba:disable Layout/LineLength` (or `Layout`) directive.

## Reasons

- A limit that no tool checks drifts. The limit belongs in the rule set that already runs in `scripts/check lint` and before every release.
- 100 characters leaves room for lines that a shorter limit would split for no gain, such as a spec's description or a row of an aligned table. The Style section asks for lines that read as one thought, which are usually far shorter.
- A per-file list is what Ameba's `Excluded` supports, and it let the limit hold for new files at once. Its weakness was that a listed file could still gain a long line, so the list was worked down rather than left to shrink as files were touched.
- One commit per file kept each rewrite reviewable on its own. Every rewrite kept the strings the code emits or compares byte-identical, proven with probes before and after; code that only runs on macOS was type-checked for that target.
- An exception, once allowed, invites the next. With none left, the proof refuses any new one, in the configuration or inline.

Principles followed:

- Manifesto 8: code must read like poetry, "structured with natural cadence".
- RFC-0008 §1: conceptual compression, code that reads like concise prose.
- Manifesto 7: a deterministic check that agents run and read.

## Verification

- `scripts/check lint` proves, in order:
  - that `Caramel/ServiceNoun` reports service nouns;
  - that `Layout/LineLength` reports a 101-character line and not a 100-character one under the framework's configuration;
  - that the rule exempts no file, by configuration or inline directive.

  It then lints the framework, which must pass. Each linter proof fails if the linter exits 0 or reports anything else, and shows the linter's own output.
- The proofs were mutation-checked, and each of these fails the check:
  - raising `MaxLength` to 140, or disabling the rule;
  - adding an `Excluded` entry;
  - adding an inline `# ameba:disable Layout/LineLength` to a source file.

  An inline disable of another Layout rule does not fail it.
