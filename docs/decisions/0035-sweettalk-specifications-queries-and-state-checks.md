# ADR 0035: SweetTalk specifications, repository queries and lifecycle checks

Date: 2026-10-13

Status: accepted. Amends [ADR 0030](0030-sweettalk-domain-language.md) decision 2 and
[ADR 0031](0031-sweettalk-services-processes-and-richer-values.md) decisions 3 and 11.

## Context

A rule such as "a sealed jar still on the shelf" was written once as a `never` or a guard
and again in the `where:` of each `finds` that looked for it, and the copies drift. `finds`
only compared attributes, so an application that needed the newest orders, a count or a
page loaded every aggregate, or reached into `Rows` from outside its contexts. A wrong
`finds` compiled until something called it. A lifecycle's `state` column took any text,
and a two-word state was written without its underscore, so `finds state:` missed it.

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
   - `Jar.all(satisfying: OnSale)`, and `satisfying: OnSale` on a `finds` or a `counts`,
     read the same rule in PostgreSQL. `!` reads as `IS NOT TRUE`, so a NULL column fails
     a rule and passes its negation in both.
2. **Repository queries** (amends ADR 0031 decision 3). The aggregate stays its own
   repository.
   - `finds verb(args)` takes `where:`, `satisfying:`, `order: {attribute: :desc}` and
     `first: expression`, at least one of them. `order:` takes `id` or attributes stored
     in one column, and `id` breaks ties.
   - `counts verb(args), where: {…}, satisfying: Rule` returns how many live aggregates
     match, in one statement; with neither, every live one.
   - `sums` and `groups` add an attribute up over the same rows, in one statement
     ([ADR 0049](0049-sweettalk-sums-and-groups.md)).
   - `finds verb(args) do |orders| … end` is the escape hatch. Its block gets the live
     rows, with removed ones and other tenants' already left out, and is one expression
     that narrows them with SugarORM's `where`, `where_null`, `order_by`, `limit` and
     `offset`; the aggregates are built from its result. It names neither `Rows`, nor
     SugarORM, nor its `Repo`.
   - A specification is checked where it is declared, and a context checks every `finds`,
     `counts`, `sums` and `groups` when it closes, whether or not anything calls them. A
     key, a state or an `order:` key the aggregate lacks, a list of entities, a derived
     value, a value of the wrong type, an unknown argument, a query name used twice or
     named like a repository method, or a `satisfying:` that is not a specification on the
     same aggregate does not compile.
   - A projection or a process declares `finds`, `counts`, `sums` and `groups` too, over
     its own attributes and its key, with `order:`, `first:` and the block; a process's
     `state:` too. Neither takes `satisfying:`, and every row is live. A query named
     `all`, `new` or `allocate` on either does not compile.
   - Only the aggregate, projection or process builds itself from rows: its loader is
     protected.
3. **Lifecycle checks** (amends ADR 0031 decision 11). A lifecycle stores each state as
   `moves` spells it, and its `state` column has a check `check_<table>_state_<hash>`,
   `"state" IN ('open', …)`. The hash is the FNV-1a 32-bit hash of the states, sorted and
   joined by commas, as eight hex digits, so a changed list of states is a new constraint.
   A name over 63 bytes does not compile.
4. **Checks.** Each refusal above has a fixture in `sweet-talk-compilation`, and
   `scripts/check integration` reads each specification the rules spec lists both ways on
   the same stored rows and compares the results.

## Reasons

- One declaration read two ways states a rule once: both readings come from the same keys,
  and the specs compare them on stored rows. A predicate block and a query block state it
  twice, and a check that compares them passes on data that lacks the case where they
  differ.
- `where:` stays declarative. PostgreSQL cannot read a rule over entities or a derived
  value, so such a rule stays a `never` or a method, and no SQL enters a rule.
- `!` as `NOT` would drop the rows whose column is NULL, which Crystal keeps.
- Evans's repository offers roots only, by criteria named in the domain, as a collection.
  The aggregate with `find`, `all`, `finds` and `counts` already does, so a separate word
  would add nothing and rename every call site.
- A page needs an order, a limit and a count; without them `all` loaded every aggregate to
  count them or show twenty.
- A caller reads `Order.newest(3)` alike whatever backs it. The block starts from rows
  already scoped and its result always goes through the loader, so it cannot forget a
  removed row or return rows instead of aggregates. Allowing only narrowing calls keeps it
  a read.
- ADR 0031 promised that a wrong query does not compile; a check inside its method waited
  for a call, so the context checks it when it closes.
- A state check holds for every writer, as a bound does. Removing a state that rows still
  hold stops the migration that validates the new check, not a later load. SugarORM
  compares an expression check by name, hence the hash.
- `where_condition` is its own SugarORM method because another `where` overload turns
  "no parameter named" into "no overload matches".

Rejected:

- **A PostgreSQL enum for the state.** `ALTER TYPE` cannot drop a value, and SugarORM
  already manages `check_…` constraints.
- **A storage block that may name `Rows`.** Its read-only rule would be a text check, and
  its queries could forget removed rows.
- **Parameters on a specification.** A `finds` takes arguments and adds a specification.
