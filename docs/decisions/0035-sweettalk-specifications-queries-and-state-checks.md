# ADR 0035: SweetTalk specifications, repository queries and lifecycle checks

Date: 2026-10-13

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 2 and
[ADR 0031](0031-sweettalk-services-processes-and-richer-values.md) decision 11.

## Context

A rule such as "a sealed jar still on the shelf" was written once as a `never` or a guard
and again in the `where:` of each `finds` that looked for it, and the copies drift. A
lifecycle's `state` column took any text, and a two-word state was written without its
underscore, so `finds state:` missed it.

## Decision

1. **Specifications** (amends ADR 0030 decision 2). `specification OnSale, on: Jar,
   where: {state: :on_shelf, sealed: true}, means: "…"`, in a context after the aggregate
   it names, is a rule and a glossary entry of kind `specification`.
   - `where:` takes what `finds` takes: attributes, `state:`, values, ids, aggregates,
     records, lists, ranges, `nil` and composite values, evaluated when the rule is asked.
     Instead it may join earlier specifications on the same aggregate with `&`, `|`, `!`
     and parentheses.
   - It adds `Jar#on_sale?`, read in Crystal by `never`, `always`, guards and methods, and
     `OnSale.satisfied_by?(jar)`.
   - `Jar.all(satisfying: OnSale)`, and `satisfying: OnSale` on a `finds`, read the same
     rule in PostgreSQL. `!` reads as `IS NOT TRUE`, so a NULL column fails a rule and
     passes its negation in both.
2. **Lifecycle checks** (amends ADR 0031 decision 11). A lifecycle stores each state as
   `moves` spells it, and its `state` column has a check `check_<table>_state_<hash>`,
   `"state" IN ('open', …)`. The hash is the FNV-1a 32-bit hash of the states, sorted and
   joined by commas, as eight hex digits, so a changed list of states is a new constraint.
   A name over 63 bytes does not compile.
3. **Checks.** Each refusal above has a fixture in `sweet-talk-compilation`, and
   `scripts/check integration` compares both readings of every specification in the spec
   domains on stored rows.

## Reasons

- One declaration read two ways states a rule once: both readings come from the same keys,
  and the specs compare them on stored rows. A predicate block and a query block state it
  twice, and a check that compares them passes on data that lacks the case where they
  differ.
- `where:` stays declarative. PostgreSQL cannot read a rule over entities or a derived
  value, so such a rule stays a `never` or a method, and no SQL enters a rule.
- `!` as `NOT` would drop the rows whose column is NULL, which Crystal keeps.
- `where_condition` is its own SugarORM method because another `where` overload turns
  "no parameter named" into "no overload matches".
- A state check holds for every writer, as a bound does. Removing a state that rows still
  hold stops the migration that validates the new check, not a later load. SugarORM
  compares an expression check by name, hence the hash.

Rejected:

- **A PostgreSQL enum for the state.** `ALTER TYPE` cannot drop a value, and SugarORM
  already manages `check_…` constraints.
- **Parameters on a specification.** A `finds` takes arguments and adds a specification.
