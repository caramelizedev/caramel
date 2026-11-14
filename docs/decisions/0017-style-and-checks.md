# ADR 0017: One formatter and one rule set hold applications and the framework, and the checks run in parallel lanes

Date: 2026-09-28

Status: accepted.

## Context

Code should read like prose while the compiler does the proving. One formatter and one linter must give every developer, agent, editor and check the same answer, and generated applications and the framework must pass the same rule set without hand fixes. The formatter never breaks a line, so long lines accumulate. The checks share one compiler cache, so they ran one after another, which is slow.

## Decision

1. **The formatter is the pinned compiler's own.** The linter runs the same formatter as one of its rules, so one command reports both.
2. **The linter is Ameba, pinned to the version the editor's language server bundles.** The pin is explicit in the configuration, so a later Ameba cannot switch on new rules silently.
3. **The rule set is Ameba's defaults plus a few Caramel rules, and every generated application receives it.** A Caramel rule covers what configuration cannot express, such as a class named for a service noun. Applications get a stricter complexity limit than Ameba's default.
4. **Applications do not adopt the line-length, typing, large-number and boolean-comparison rules.**
5. **The lint command reports and never rewrites, and the linter is built with the release it belongs to.**
6. **Generated code passes the rule set as generated.** Where a rule misreads a construct, such as the paragraph element in a view, the rule set excludes that place and keeps the rule.
7. **The framework follows the same rule set, and every inline disable names its reason.** The framework's differences are few, and each comes from its layout or its kind of code.
8. **A framework line holds at most 100 characters, and no file is exempt.** The limit is a lint rule, and the lint check proves that the rule is on and that neither the configuration nor an inline directive exempts anything.
9. **What a linter cannot check is written down in the contributors' guide.**
10. **A full check run deals its runs to lanes that run side by side.** The lane count follows the machine's cores and memory, and one lane keeps serial behaviour.
11. **Each lane beyond the first has a persistent toolchain prefix of its own.** The prefix has private compiler and dependency caches, so lanes compete only for CPU, memory and free ports.
12. **A run is placed by what it took last time on this machine, and it keeps its lane while the loads stay close.**
13. **A check that generates an application keeps it at a stable path with a persistent cache.** The path is locked while the check runs, so a second run of the same check fails at once instead of disturbing the first.

## Reasons

- A rule set only helps if the same one runs everywhere. Pinning the editor's Ameba for the command line and for checks gives one answer.
- Ameba is the Crystal ecosystem's linter and runs natively, so the tooling needs no Node or Python layer.
- A deterministic linter that agents run and read keeps tooling stateless.
- Applying the rule set to the framework found real improvements: repeated checks became named predicates, and presence assertions became types that carry the fact.
- A service noun holds a verb that belongs on its subject. A tight complexity limit keeps an action a single thought.
- Rejected: auto-fixing in the lint command, because Ameba's corrections are not all safe: one changes behaviour, another renames files that specs require.
- Rejected: a line limit in applications. A generated resource's lines grow with its fields, and the formatter owns layout.
- Rejected: the typing rules. Contracts are typed, not every method.
- Rejected: the large-number rule. It rewrites identifiers such as migration versions and protocol codes, which read worse.
- Rejected: the boolean-comparison rule. Its automatic correction changes what a comparison with `false` means.
- A limit that no tool checks drifts. The limit belongs in the rule set that already runs before every release.
- 100 characters leaves room for lines that a shorter limit would split for no gain, such as a spec's description or a row of an aligned table.
- Rejected: a per-file exemption list for the line limit, because a listed file can still gain a long line and an exception, once allowed, invites the next.
- Contention between lanes is moderate, and the lanes still more than halve the suite.
- Rejected: a fresh prefix per run, because it compiles cold every time and costs more than the contention it avoids.
- A run's wall time is the build step plus its heaviest lane. Recording each machine's own durations and letting the lane count follow the machine balance the lanes without a fixed number for any machine.
- A run that changes lane compiles cold in the new prefix, which can double its time.
- The compiler keys its cache by the program's absolute path, so a generated application at a fresh temporary path compiled cold on every run.
- Rejected: one spec program per spec directory. The lanes were already balanced, and compiling the framework into several programs adds CPU time that a machine with few lanes pays in wall time.
- Each lane's compiler needs a large share of memory, so memory bounds the lane count.
