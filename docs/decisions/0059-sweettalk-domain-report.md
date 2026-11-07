# ADR 0059: SweetTalk refuses unused edges

Date: 2026-11-07

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 3 and
[ADR 0044](0044-sweettalk-shared-kernels.md) decision 2.

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
3. **`follows:` and `locks:` stay declared.** Nothing infers them.

## Reasons

- A compiled context map exists to turn drift into compile errors (ADR 0030). An edge
  nothing uses is drift, and it can trip the cycle check for a dependency that is gone.
- The rule reads the same text as the refusals of a foreign name, so it needs no types and
  no tool.
- `follows:` is a strategic choice that ADR 0036 builds on; a declared edge stays in the
  context's head, where a reader looks.

Rejected:

- **A warning, or listing unused edges in a report.** A warning scrolls past; the build
  is where SweetTalk keeps the map true.
- **Inferring `follows:` from the text.** It would hide the dependency from the context's
  head (ADR 0044's reason for `shares:`).
