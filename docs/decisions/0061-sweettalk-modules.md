# ADR 0061: SweetTalk modules

Date: 2026-11-07

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 1.

## Context

Every SweetTalk word ships to every program that requires `caramel/sweet_talk`. Some words
bring a dependency, some serve one family of domains, and some add a strictness other
domains would read as noise. Five requires already followed an unwritten rule: i18n
([ADR 0024](0024-internationalization.md)), tenancy ([ADR 0025](0025-multi-tenancy.md)),
the recorder and OTLP ([ADR 0028](0028-crema-production-access.md)) and decimal values
([ADR 0047](0047-sweettalk-decimal-and-json-values.md)). Nothing said when the next word
gets a require of its own.

## Decision

1. **M1. A word goes in a module, `require "caramel/sweet_talk/<name>"`, when at least one
   of these holds:** it brings a dependency the core lacks; it is the vocabulary of one
   family of domains; or it adds a check some domains would reject, attached to its own
   words.
2. **M2. The core model is never a module:** contexts, kernels, values, aggregates,
   entities, events, commands, services, units, calculations, `never`, `always`, the
   context map and the glossary.
3. **M3. A module requires its dependencies and the core.** It has no flag or
   configuration: the require is the whole opt-in.
4. **M4. A module's word used without its require fails compilation and names the
   require.**
5. **M5. A program without the require holds none of the module's code.**
   `scripts/check sweet-talk-compilation` builds one application per module and the same
   application without it, and fails when a string only the module holds is in the binary
   without the require, or missing with it.
6. **M6. A module never changes what a core word means.** It adds words, and options that
   only its own types accept.
7. **M7. Lanes run the core alone, each module alone, and all modules together.** A pair
   runs on its own only when one module names the other. The core alone is
   `sweet-talk-compilation`'s fixtures and its application without modules; all modules
   together are `spec/sweet_talk`, under `scripts/check integration`.
8. **M8. A rule depends on what a domain declares or requires, never on `subdomain:`.** A
   module word that a second family of domains needs moves to the core, and its ADR is
   edited in the same change.
9. **The modules.**
   - `caramel/sweet_talk/decimal` ([ADR 0047](0047-sweettalk-decimal-and-json-values.md)):
     `Decimal(P, S)` values. Its dependency is GMP, through `big`.
   - `caramel/sweet_talk/money` ([ADR 0063](0063-sweettalk-money.md)): currencies,
     amounts, quotes and allocations, the vocabulary of domains that keep books. It
     requires `caramel/sweet_talk/decimal`.

## Reasons

- A require is the cheapest opt-in Crystal has: an absent file is never parsed, declares
  nothing and links nothing, so a program pays only for the words it asks for.
- The three tests of M1 name the costs a word puts on programs that do not use it: a
  link-time library, a vocabulary they do not speak, a refusal they did not ask for.
- The core model is what every domain shares; a context without aggregates, or an
  aggregate without `never`, would not be SweetTalk.
- A flag beside a require would be a second switch for one choice, and a program could set
  one without the other.
- Naming the require in the compile error turns a missing line into a one-line fix, as ADR
  0047 already does for `Decimal(…)`.
- Proving absence on the built binary, not on the source, catches a module reached through
  a require nobody meant.
- A module that redefines a core word would make a domain's meaning depend on a line far
  from it. Adding words keeps every core sentence true in every program.
- Running every pair would grow the lanes with the square of the modules; two modules that
  do not name each other meet only through the core, which each lane already runs.
- A label measures nothing ([ADR 0036](0036-sweettalk-strategic-design.md) rejects rules
  that depend on the subdomain). What a domain declares or requires is what it uses.

Rejected:

- **One require for everything.** Every program would link GMP and read every family's
  words in its glossary and errors.
- **Folding the rules into ADR 0047.** They govern every module, and decimal is one.
- **Deciding per module.** The five requires already agreed; writing the rule down keeps
  the next one from deciding differently by accident.
