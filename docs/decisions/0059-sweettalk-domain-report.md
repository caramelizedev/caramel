# ADR 0059: SweetTalk refuses unused edges and reports its domain

Date: 2026-11-07

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 3 and
[ADR 0044](0044-sweettalk-shared-kernels.md) decision 2, and adds `frappe glossary` and `frappe contexts` to
[ADR 0013](0013-frappe-cli-check-mrdp.md) decision 1.

## Context

A context could declare `follows:` and `shares:` it no longer used. The context map refused
the short direction, a name with no edge, but not the long one. An application that moved
the work across five contexts into its own code kept five `follows:` edges nothing named,
and each still counted in the cycle check.

## Decision

1. **An unused `follows:` does not compile.** `follows: B` in context A is used when A's
   text, or a border of A other than `border B`, names `B::` or calls `B.verb`. Otherwise
   `SweetTalk.context_map` refuses it at A's line, naming B and saying to remove it from
   `follows:`. A process step's event and a border's own text do not count: neither needs
   the edge.
2. **An unused `shares:` does not compile.** `shares: K` in a context or kernel is used
   when its text or one of its borders names `K::`. Otherwise the context map refuses it at
   its line, saying to remove K from `shares:` and the sharer from K's `shared_by:`. The
   rule sits beside the count of each kernel word's sharers, which runs first.
3. **`follows:` and `locks:` stay declared.** Nothing infers them, and neither does
   `changes:`: ADR 0046's run-time `Boundary` stays the check.
4. **`SweetTalk.report` is the detailed glossary.** It returns each glossary term, in the
   glossary's order, as a `SweetTalk::Entry` with the facts its declaration holds: a
   context's `follows` and `shares`, a kernel's `shared_by`, a value's `wraps`, `at_least`,
   `at_most` and `one_of`, an aggregate's or process's `states` and `moves`, an event's
   `handlers` in the order they run, and a unit's `changes`, `locks` and `once_by`.
   `SweetTalk.glossary` is unchanged.
5. **The application answers `glossary`** with the report and the context map as one JSON
   document, as it answers `schema` (ADR 0008) and `requirements` (ADR 0057).
6. **`frappe glossary [--json]` and `frappe contexts [--mermaid]` print them.** Frappé
   compiles the application, runs `glossary` and keeps the document in
   `.caramel/glossary.json` with the source signature it read; an unchanged source answers
   from it. `glossary` prints Markdown, `--json` the document; `contexts` prints each
   context with its edges, `--mermaid` a flowchart.

## Reasons

- A compiled context map exists to turn drift into compile errors (ADR 0030). An edge
  nothing uses is drift, and it can trip the cycle check for a dependency that is gone.
- The rule reads the same text as the refusals of a foreign name, so it needs no types and
  no tool.
- `follows:` is a strategic choice that ADR 0036 builds on; a declared edge stays in the
  context's head, where a reader looks.

- A report derived on demand is correct by construction; a committed copy would drift.
- A typed checker over the compiler's call graph was measured and not adopted: its walk is
  path-insensitive, so a branch a run-time flag never takes adds an aggregate the unit does
  not change. Inferring `changes:` waits for a front-end.

Rejected:

- **A warning, or listing unused edges in a report.** A warning scrolls past; the build
  is where SweetTalk keeps the map true.
- **Inferring `follows:` from the text.** It would hide the dependency from the context's
  head (ADR 0044's reason for `shares:`).
