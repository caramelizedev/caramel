# ADR 0036: SweetTalk compiles the context map, and every relationship between contexts is declared, checked and used

Date: 2026-10-08

Status: accepted.

## Context

An application with a rich domain has no word for a bounded context, and nothing stops one context from reaching into another's types. Naming the relationships is not enough: a reader cannot tell which context is the core, an upstream context cannot say which of its names others may depend on, and a payment gateway has no place in the domain for its translation. Two contexts that own part of a model together either put it in one of them or keep two copies that drift. A map that refuses only a name with no edge drifts the other way, and keeps edges nothing names.

## Decision

1. **A context adopts another's model with `follows:` or translates it in a `border`.** A border is the context's only code that may name a context it does not follow.
2. **The context map is checked at compile time.** A foreign name with no edge and a cycle of dependency edges do not compile. A call on another context's module is a reference like a type name. Reacting to another context's event is not a dependency, so two contexts may react to each other.
3. **An edge nothing uses does not compile.**
4. **Edges stay declared.** Nothing infers a context's edges, or what a unit locks and changes, from the text.
5. **A context may name its subdomain, and the name changes no rule.** The label is optional.
6. **A context may publish a language.** A publisher lists, inside its body, the names other contexts may use, and followers and borders alike name only those. Its events stay open to every context that may name it.
7. **A border may face a system outside the program.** It is the only code in a context that may make an outbound HTTP call, and it reacts to no event.
8. **A kernel is a part of a model that named contexts share, and both sides say it.** The kernel lists its sharers and each sharer says it shares the kernel. It holds values and aggregates, and may share an earlier kernel.
9. **Only sharers name a kernel.** No other context names, follows or borders it, and a kernel names no context and calls no outside system.
10. **Every word of a kernel is shared.** A value or aggregate that fewer than two sharers name does not compile.
11. **A kernel stores like a context.** With tenancy its rows belong to the tenant ([ADR 0033](0033-framework-boundary.md)).
12. **The glossary and the context map are derived from the compiled application.** The application binary prints them, through the commands the shard declares to Frappé. No copy is committed or kept.

## Reasons

- Reacting to an event depends on its fields, not on the publisher's model. Counting only dependency edges lets contexts react to each other while their types point one way.
- A module method call is a dependency as much as a type name. Leaving it out lets a context reach another with no edge, so a cycle of calls compiles.
- A compiled context map exists to turn drift into compile errors ([ADR 0030](0030-scope-and-modules.md)). An edge nothing uses is drift, and it can trip the cycle check for a dependency that is gone.
- Rejected: a warning, or listing unused edges in a report. A warning scrolls past; the build is where SweetTalk keeps the map true.
- Rejected: inferring `follows:` from the text. It would hide the dependency from the context's head, where a reader looks.
- Rejected: a typed checker over the compiler's call graph. Its walk is path-insensitive, so a branch a run never takes adds an aggregate the unit does not change.
- Distillation tells a reader where modelling effort pays. It stays a label because no check can measure how carefully a core domain is modelled, and optional because a label is not worth failing every existing domain.
- In one binary an open-host service is a set of calls, and its published language the types they take and return. Listing both makes the upstream's promise a compile-time fact: it can change everything else without breaking a follower.
- Rejected: the published list as an option on `context`. Inside the body it sees the names declared before it, so a misspelt name is refused at its line.
- An outside system's answers are another model. Confining HTTP to a border makes the translation the only place where it can leak in, and lets a spec fake the system at the wire without touching the domain.
- An outside system emits no events; a webhook arrives through an action, which runs a command.
- Rejected: a partnership word. Two contexts that depend on each other form the cycle the map refuses; partners react to each other's events, which the map already allows.
- Rejected: RPC or HTTP export of a context. Contexts are modules in one binary.
- Rejected: a small context that several contexts follow, in place of a kernel. The followed context owns the model and nothing records who must agree to a change.
- A closed list on the kernel makes joint ownership a compile-time fact: a context that starts to use the kernel edits it, where every owner reviews the change.
- Rejected: one side only. The kernel's list alone hides the dependency from the sharer's head; the sharer's word alone lets any context join, which is following again.
- Aggregates and events belong in a kernel because what two contexts must agree on often has a lifecycle. Services, policies, projections and processes act for one context, so a sharer holds them.
- Rejected: independent kernels. A value of one kernel that needs another's would force the two to merge or the value to be copied.
- Rejected: checking only that each sharer names the kernel. It misses a word only one sharer uses.
- Storing like a context reuses tables, tenancy, queries and their checks.
- Rejected: a central kernel. A kernel is shared between contexts, not between tenants.
- A report derived on demand is correct by construction; a committed copy would drift.
