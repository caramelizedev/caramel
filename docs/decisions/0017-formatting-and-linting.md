# ADR 0017: Formatting and linting

Date: 2026-09-28

Status: accepted. Decisions 4 and 6 are amended by [ADR 0021](0021-line-length.md).

## Context

Code should read like prose while the compiler does the proving, and one formatter and linter must give every developer, agent, editor and check the same answer. Generated applications and the framework itself must pass the same rule set without hand fixes after every `frappe make resource`.

## Decision

1. **The formatter is `crystal tool format`**, from the pinned compiler. Ameba's `Lint/Formatting` rule runs the same formatter, so one command reports both.
2. **The linter is Ameba 1.7.0**, the version `ameba-ls` bundles, so the command line and the editor agree.
   - It is a development dependency of the framework, and both configurations pin `Version: "1.7.0"`, so a later Ameba cannot switch on new rules silently.
   - `scripts/build-lint` builds `bin/frappe-lint`: Ameba's rules plus Caramel's.
3. **The rule set is Ameba's defaults, plus Caramel's additions.** It lives in `templates/application/.ameba.yml`, which every generated application receives.
   - `Caramel/ServiceNoun`, a Caramel rule: reports classes, structs and modules named for a service noun. These are names ending in `Service`, `Handler`, `Manager`, `Factory`, `Controller`, `Helper`, `Util`, `Utils` or `Utility`, or starting with `Abstract`. The verb belongs on its subject.
   - `Metrics/CyclomaticComplexity` at 10: an action is a single thought, not a junk drawer.
   - `Documentation/Admonition`: shipped code carries no undated or overdue `TODO`, `FIXME` or `BUG` comments.
   - Ameba's defaults already carry the rest:
     - `Naming/PredicateName` and `Naming/QueryBoolMethods`: predicates read as questions (`active?`, not `is_active` or a bare `Bool` getter).
     - `Naming/AccessorMethodName` and `Naming/BlockParameterName`: plain accessors and descriptive block names.
     - `Style/VerboseBlock`: `each(&.terminate!)`.
     - The redundancy rules (`RedundantReturn`, `RedundantBegin`, `RedundantNext`, `RedundantSelf`, `RedundantNilInControlExpression`).
     - `Style/NegatedConditionsInUnless` and `Style/UnlessElse`: conditions read positively.
     - `Lint/NotNil`: the compiler proves presence; code does not assert it with `not_nil!`.
4. **Not adopted** in applications (the framework enables `Layout/LineLength`, [ADR 0021](0021-line-length.md)):
   - `Layout/LineLength`: a generated resource's lines grow with its fields, and the formatter owns layout.
   - The `Typing/*` rules: contracts are typed, not every method.
   - `Style/LargeNumbers`: it rewrites identifiers such as migration versions (`20260927000001_i64`) and protocol codes, which read worse. Semantic units are a library feature, not a lint.
   - `Lint/ComparisonToBoolean`: its automatic correction turns `json["key"]? == false` into `!json["key"]?`, which is never true for a present `JSON::Any`.
5. **Applications** get the rule set and two commands:
   - `frappe lint [--agent|--human]` runs `bin/frappe-lint` in the project. It prints Ameba's report on a TTY and MRDP otherwise: `ERR LINT_<RULE> at file:line:col`, where `<RULE>` is the rule's group and name in upper snake case (`LINT_CARAMEL_SERVICE_NOUN`), and `MSG` ends with the rule's own name for `# ameba:disable`. It prints `OK lint <n> files` when clean. A `Lint/Formatting` finding (`ERR LINT_LINT_FORMATTING`) carries `FIX: frappe format`.
   - `frappe lint` reports and never rewrites, because Ameba's corrections are not all safe: `Lint/ComparisonToBoolean` changes behaviour, and `Lint/SpecFilename` renames support files that specs require.
   - `frappe format` runs the pinned formatter on the project's `src`, `config`, `app`, `db` and `spec`.
   - `frappe installations install` builds a release's linter with the release, and a registered checkout builds its linter on first use. Either rebuilds it after its sources or `shard.lock` change. A frappe older than 0.3.0 installs releases without the linter; `frappe doctor` then names `frappe installations install <version>`, which builds it.
   - Generated code passes the rule set:
     - generated actions pass view inputs as constructor arguments ([ADR 0018](0018-blueprint-views.md)), so no local exists only for a template to read;
     - migrations quote a SQL heredoc only when it contains `#{` or a backslash, the only text an unquoted heredoc would change. A backslash that is no Crystal escape sequence gets a reasoned `Style/HeredocEscape` directive, since obeying that rule would drop it.
   - The application rule set globs `app/**/*.cr` and excludes `app/views/**/*.cr` from `Lint/DebugCalls`: in a Blueprint view `p` is the paragraph element, not the debug print ([ADR 0018](0018-blueprint-views.md)).
6. **The framework follows the same rule set**, with `Layout/LineLength` enabled by ADR 0021, through `.ameba.yml` at the repository root, run by `scripts/check lint`. Apart from the globs each layout needs, it differs in six places:
   - Complexity keeps Ameba's default limit of 12. Dispatch tables, parsers, scanners, state machines, and step-by-step validation or process-lifecycle code that exceed it carry an inline `ameba:disable` naming why, so new code still meets the limit.
   - Crystal under `scripts/`, the checks and the release tool, is exempt from the complexity rule: its branches are scenario steps and assertions.
   - Specs and the Crystal under `scripts/` may assert presence with `not_nil!`.
   - Fixture data is excluded: some of it is invalid on purpose, and checks assert exact positions inside it.
   - `Lint/SpecFilename` also ignores `spec/**/support/**`, where each product keeps files its specs require.
   - `Lint/DebugCalls` has no view exclusion: the framework's views live in fixture applications, which the fixture exclusion already covers.
7. **Every inline `ameba:disable` names its reason** on the directive line, above the code it covers.

## Reasons

- A rule set only helps if the same one runs everywhere. Pinning the editor's Ameba for the command line and for checks gives one answer.
- Ameba is the Crystal ecosystem's linter and runs natively. A Caramel rule covers what its configuration cannot express. The editor's pinned `ameba-ls` binary cannot load Caramel's rule; it ignores the key and applies the rest of the rule set, except `Layout/TrailingWhitespace`, `Layout/TrailingBlankLines` and `Lint/Formatting`, which it turns off while editing.
- Applying the rule set to the framework found real improvements: repeated "private owned file" checks became named predicates, SIGHUP shuts `latte daemon` and `frappe dev` down cleanly, and `not_nil!` assertions became types that carry the fact.
- A deterministic linter that agents run and read as MRDP keeps tooling stateless.
- Native tooling needs no Node or Python layer.
- Rejected: auto-fixing in `frappe lint`, because some corrections change behaviour or break requires.
