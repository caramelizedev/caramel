# ADR 0017: Formatting and linting for RFC-0008

Date: 2026-09-28

Status: accepted.

## Context

RFC-0008 asks for code that reads like prose while the compiler does the proving. Nothing checked it:

- Generated applications had no lint configuration. The editor ran `ameba-ls` 0.2.0, which bundles Ameba 1.7.0, with default rules.
- The framework itself had never been linted. Ameba's defaults reported 760 issues in 126 of its 193 files, and `crystal tool format` would have changed 23 files.
- A new application failed Ameba's defaults in its generated entry point and configuration. Each `frappe make resource` added more: form locals Ameba could not see, verbose blocks, quoted SQL heredocs with nothing to escape.

## Decision

1. **The formatter is `crystal tool format`**, from the pinned compiler. Ameba's `Lint/Formatting` rule runs the same formatter, so one command reports both.
2. **The linter is Ameba 1.7.0**, the version `ameba-ls` bundles, so the command line and the editor agree.
   - It is a development dependency of the framework, and both configurations pin `Version: "1.7.0"`, so a later Ameba cannot switch on new rules silently.
   - `scripts/build-lint` builds `bin/frappe-lint`: Ameba's rules plus Caramel's.
3. **The rule set is Ameba's defaults, plus what RFC-0008 asks for.** It lives in `templates/application/.ameba.yml`, which every generated application receives.
   - `Caramel/ServiceNoun`, a Caramel rule (§1, §2.1): reports types named for a service noun. These are names ending in `Service`, `Handler`, `Manager`, `Factory`, `Controller`, `Helper`, `Util`, `Utils` or `Utility`, or starting with `Abstract`. The verb belongs on its subject.
   - `Metrics/CyclomaticComplexity` at 10 (§2.5): an action is a single thought, not a junk drawer.
   - `Documentation/Admonition`: shipped code carries no `TODO`, `FIXME` or `BUG` placeholders.
   - Ameba's defaults already carry most of RFC-0008:
     - `Naming/PredicateName` and `Naming/QueryBoolMethods`: predicates read as questions (`active?`, not `is_active` or a bare `Bool` getter).
     - `Naming/AccessorMethodName` and `Naming/BlockParameterName`: plain accessors and descriptive block names.
     - `Style/VerboseBlock` (§2.2): `each(&.terminate!)`.
     - The redundancy rules (`RedundantReturn`, `RedundantBegin`, `RedundantNext`, `RedundantSelf`, `RedundantNilInControlExpression`): conceptual compression.
     - `Style/NegatedConditionsInUnless` and `Style/UnlessElse`: conditions read positively.
     - `Lint/NotNil` (§1): the compiler proves presence; code does not assert it with `not_nil!`.
4. **Not adopted**, with reasons:
   - `Layout/LineLength`: a generated resource's lines grow with its fields, and the formatter owns layout.
   - The `Typing/*` rules: type restrictions everywhere are the ceremony RFC-0008 compresses away. Its examples type contracts, not every method.
   - `Style/LargeNumbers`: of the nine literals it rewrote in this repository, eight were migration timestamps (`20260927000001_i64` became `20_260_927_000_001_i64`) and one was PostgreSQL's SSLRequest code. Every one was an identifier, not a quantity, and every one read worse. The literals are restored. Semantic units (§2.3) are a library feature, not a lint.
   - `Lint/ComparisonToBoolean`: its automatic correction turns `json["key"]? == false` into `!json["key"]?`, which is never true for a present `JSON::Any`. Applying it to this repository would have silently changed the CA trust guard in `scripts/checks/support/latte_fixture.cr` and weakened the browser check's CSRF assertions, so those corrections were reverted.
5. **Applications** get the rule set and two commands:
   - `frappe lint [--agent|--human]` runs `bin/frappe-lint` in the project. It prints Ameba's report on a TTY and MRDP otherwise: `ERR LINT_<RULE> at file:line:col`, where `<RULE>` is the rule's group and name in upper snake case (`LINT_CARAMEL_SERVICE_NOUN`), and `MSG` ends with the rule's own name for `# ameba:disable`. It prints `OK lint <n> files` when clean.
   - `frappe lint` reports and never rewrites. Ameba's corrections are not all safe: `Lint/ComparisonToBoolean` changes behaviour, and `Lint/SpecFilename` renamed a required spec support file here, which broke the suite.
   - `frappe format` runs the pinned formatter on the project's `src`, `config`, `app`, `db` and `spec`.
   - The installation builds the linter on first use, and again after its sources or `shard.lock` change.
   - Generated code passes the rule set:
     - the form action hands `action`, `method` and `form` to its views as named locals, which the other actions already did;
     - migrations quote a SQL heredoc only when it contains `#{` or a backslash, the only text an unquoted heredoc would change.
6. **The framework follows the same rule set** through `.ameba.yml` at the repository root, run by `scripts/check lint`. It differs in five places:
   - Complexity keeps Ameba's default limit of 12. Dispatch tables, parsers, scanners and state machines that exceed it carry an inline `ameba:disable` naming why, so new code still meets the limit.
   - Checks are end-to-end scenarios, exempt from the complexity rule.
   - Specs and checks may assert presence with `not_nil!`.
   - Fixture data is excluded: some of it is invalid on purpose, and checks assert exact positions inside it.
   - `Lint/SpecFilename` also ignores `spec/**/support/**`, where each product keeps files its specs require.
7. **Every inline `ameba:disable` names its reason** on the directive line, above the code it covers.

## Reasons

- A rule set only helps if the same one runs everywhere. Pinning the editor's Ameba for the command line and for checks gives one answer to "is this code poetic enough".
- Ameba is the Crystal ecosystem's linter and runs natively. A Caramel rule covers what its configuration cannot express. The editor's pinned `ameba-ls` binary cannot load Caramel's rule; it ignores the key and applies the rest of the rule set.
- Applying the rule set to the framework found real improvements, not just style:
  - thirteen hand-rolled "private owned file" checks became two named predicates, `StateSecurity.owned_file?` and `private_file?`;
  - SIGHUP now shuts `latte daemon` and `frappe dev` down cleanly through `Process.on_terminate`;
  - `not_nil!` assertions became types that carry the fact.

Principles followed:

- Manifesto 8: code must read like poetry.
- RFC-0008 §1, §2.1, §2.2 and §2.5, as mapped above.
- Manifesto 7: a deterministic linter that agents run and read as MRDP.
- Manifesto 3: native tooling, with no Node or Python layer.

## Verification

- `scripts/check lint` builds `bin/frappe-lint` and proves on a fixture that `Caramel/ServiceNoun` reports service nouns and not subjects or actions. It then lints the framework, which must pass.
- `scripts/check frappe-project` requires a generated application with two resources to print `OK lint`. A planted, misformatted `InvitationService` must yield exactly `ERR LINT_LINT_FORMATTING` with `FIX: frappe format`, then `ERR LINT_CARAMEL_SERVICE_NOUN`; `frappe format` must then fix its layout.
- `scripts/check editor-tools` runs `ameba-ls` with both rule sets.
- `spec/frappe/schema_diff_spec.cr` pins when a migration's heredoc is quoted.
