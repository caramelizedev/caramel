# ADR 0036: SweetTalk strategic design: subdomains, published languages and outside systems

Date: 2026-10-13

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decisions 2 and 3. Its
rejection of a shared kernel word is reversed by
[ADR 0044](0044-sweettalk-shared-kernels.md).

## Context

ADR 0030 checks two relationships between contexts: `follows:`, which adopts another
context's model as it is, and `border`, which translates it. Three things are missing. A
reader cannot tell which context is the core of the business. An upstream context cannot
say which of its names others may depend on, so every follower depends on all of it. And
an application that talks to a payment gateway or a carrier has no place in its domain
for that translation. The map also misses calls: `Catalogue.price_of(tea)` from a context
that neither follows Catalogue nor sits in its border compiles, and draws no edge.

## Decision

1. **A context may name its subdomain.** `context Name, subdomain: :core, …` takes
   `:core`, `:supporting` or `:generic`; any other value does not compile, and leaving it
   out is allowed. It changes no rule. `SweetTalk::Term` gains `subdomain : String?`, its
   last field, defaulting to nil, and every glossary term carries its context's.
2. **A call is a reference** (amends ADR 0030 decision 3). In context A, `B.verb`, a call
   on another context's module such as one of its services, counts as naming `B::`: it
   compiles where A follows B or inside `border B`, and in a border it draws a dependency
   edge.
3. **A context may publish a language.** `publishes Cents, Tea::Id, price_of` lists the
   context's types and services that other contexts may name; naming a type publishes
   what it contains. Once a context publishes, every other context, a follower or a
   border alike, names only those and the publisher's events: every event stays nameable
   by any context that may name the publisher, because a follower reacts to them. A name
   it does not publish does not compile, at the line that names it when the publisher is
   declared first, and when the program's checks run otherwise. `publishes` lists only
   names declared before it in the same context. A context that does not publish keeps
   ADR 0030's rules.
4. **A border may face a system outside the program.** `border Cards, outside: "…" do …
   end` declares a module `Cards` in the context and an `outside` edge in the context
   map; `outside:` is the line its glossary entry shows, with kind "outside", and anything
   but a string literal does not compile. Code in a context may name `Caramel::Outbound`
   or `HTTP::Client` only there, and a context that does elsewhere does not compile. Like
   the `Rows::` and `B::` checks, this one reads the code as written: an alias, or a
   method defined outside the context, is not caught. The border holds no `whenever` or
   `compensate`, because an outside system emits no events; a webhook arrives through an
   action, which runs a command. An outside border named like a context does not compile.
5. **Checks.** Each refusal above has a fixture in `sweet-talk-compilation`, and
   `spec/sweet_talk` runs a domain that uses all four decisions against PostgreSQL, with
   the outside system faked by `Corretto.stub_wire`.

## Reasons

- Distillation tells a reader where modelling effort pays. It stays a label, because no
  check can measure how carefully a core domain is modelled, and optional, because a
  label is not worth failing every existing domain.
- `subdomain:`, not `kind:`, because `Term` already has `kind` ("context", "value", …) and
  models carry `SWEETTALK_KIND`; one word for two ideas would make the glossary ambiguous.
- A module method call is a dependency as much as a type name. Leaving it out let a
  context reach another with no edge, so a cycle of calls compiled.
- In one binary an open-host service is a set of calls, and its published language the
  types they take and return. Listing both in one word makes the upstream's promise a
  compile-time fact: it can change everything else without breaking a follower.
- Events stay open, because reacting depends on an event's fields, not on the
  publisher's model (ADR 0030 Reasons).
- The check runs where the names are written when it can, so the message names the line,
  and falls back to the whole-program check for a publisher declared later.
- An outside system's answers are another model. Confining HTTP to a border makes the
  translation the only place where it can leak in, and lets a spec fake the system at
  the wire, as Corretto requires, without touching the domain.

Rejected:

- **Rules that depend on the subdomain**, such as more checks for the core. None measures
  what it claims.
- **A shared kernel word.** A small context that several contexts follow already shares
  a model, with a dependency edge each; joint ownership is a team practice, not a type.
  [ADR 0044](0044-sweettalk-shared-kernels.md) reverses this.
- **A partnership word.** Two contexts that depend on each other form the cycle ADR 0030
  refuses; partners react to each other's events, which the map already allows.
- **RPC or HTTP export of a context.** Contexts are modules in one binary.
- **`publishes:` on `context`.** The word inside the body sees the names declared before
  it, so a misspelt name is refused at its line.
