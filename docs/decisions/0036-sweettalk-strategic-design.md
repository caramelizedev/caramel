# ADR 0036: SweetTalk strategic design: subdomains, published languages and outside systems

Date: 2026-10-13

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 2.

## Context

ADR 0030 checks two relationships between contexts: `follows:`, which adopts another
context's model as it is, and `border`, which translates it. A reader cannot tell which
context is the core of the business.

## Decision

1. **A context may name its subdomain.** `context Name, subdomain: :core, …` takes
   `:core`, `:supporting` or `:generic`; any other value does not compile, and leaving it
   out is allowed. It changes no rule. `SweetTalk::Term` gains `subdomain : String?`, its
   last field, defaulting to nil, and every glossary term carries its context's.

## Reasons

- Distillation tells a reader where modelling effort pays. It stays a label, because no
  check can measure how carefully a core domain is modelled, and optional, because a
  label is not worth failing every existing domain.
- `subdomain:`, not `kind:`, because `Term` already has `kind` ("context", "value", …) and
  models carry `SWEETTALK_KIND`; one word for two ideas would make the glossary ambiguous.

Rejected:

- **Rules that depend on the subdomain**, such as more checks for the core. None measures
  what it claims.
