# ADR 0049: SweetTalk sums and groups

Date: 2026-10-31

Status: accepted. Amends [ADR 0035](0035-sweettalk-specifications-queries-and-state-checks.md)
decision 2 and [ADR 0007](0007-sugarorm-schemas-changesets-preload.md) decision 5. Decision 3
is amended by [ADR 0064](0064-uuidv7-identity.md), and decision 1 by
[ADR 0065](0065-sweettalk-contexts-across-files.md). Decisions 2 and 3 are amended by
[ADR 0063](0063-sweettalk-money.md) decision 10.

## Context

A declared read could find or count aggregates, and nothing else. A total, the first
question a report asks, was a projection kept current by `whenever` and added up in Crystal
over the rows a `finds` returned, or `SugarORM.sql` outside the context with the tenant
predicate written by hand, where a forgotten `WHERE account_id` added every tenant's rows
together with no error (#249, after #133 and #169).

## Decision

1. **`sums` and `groups` are declared like `counts`.** `sums spent_by(member : Account),
   of: Line.price, where: {member: member, state: :placed}` and `groups
   priced_by_tea(member : Account), of: Line.price, by: Line.tea, where: {…}` are declared
   on an aggregate, a projection or a process, take `where:` and `satisfying:` as `counts`
   does, and are checked once the program's top level is complete. `of:` and `by:` name an
   attribute of the model by symbol, `of: :total`, or an attribute of one of the
   aggregate's first-level entities, `of: Line.price`; a `groups` that adds up an entity's
   attribute groups by an attribute of that entity, or by `:id`. The name is unique among
   the model's queries. When `of:` names an entity's attribute, `where:` also takes
   conditions on each entity it adds up, under the name of the list that holds them:
   `where: {state: :posted, lines: {segment: segment}}`. They take what the aggregate's own
   take but `state:`. A `finds` or `counts` filters on no list.
2. **Return types.** `sums` returns the attribute's type: the `Int32`, `Int64` or `Float64`
   of a column, or the value. A sum no row matches is the zero of that type, built the way
   every sum is. `groups` returns `Array(NamedTuple(by: K, total: T))`, `K` the key's type
   with `?` when the attribute is optional, with no row for a key no matching row has.
   `by: :id` keys are the aggregate's `Id`. An amount adds up as ADR 0063 decision 10 says.
3. **What is summable and groupable.** `of:` is an `Int32`, `Int64` or `Float64` column, a
   value that wraps `Int32`, `Int64` or a decimal, whose lower bound is absent or 0 and
   whose upper bound is absent, or an amount (ADR 0063 decision 10): a sum of values each
   at least 0 is at least 0, so that bound holds, while an upper bound or any other lower
   bound can be broken by the sum. `by:` is a `String`, `Int32`, `Int64`, `UUID` or `Bool`
   column, a value wrapping a whole number, text, a day or a decimal, an aggregate the
   model refers to (its `Id`), `:state`, `:id`, the aggregate each entity belongs to, when
   `of:` names an entity's attribute, or an amount, by its currency. A `Float64`, a `Time`,
   a JSON document, a value with parts other than an amount, a record or a list of entities
   has no one-column key and does not compile.
4. **One statement through SugarORM.** `sum_text(:field)` reads
   `coalesce(sum(col), 0)::text` and `group_sum_text(:by, :of)` one such row per key, each
   over the query's conditions, the tenant's included; a sum of an entity's attribute
   narrows the entity's rows with `where_in(:parent_id, rows)`, `IN (SELECT id FROM …)`
   with the aggregate's conditions, so removed aggregates and other tenants' rows are
   excluded from the entity's sum as from a `finds`. PostgreSQL returns the sum as text,
   exact for integers, bigints and numerics, and the generated method builds the type. An
   entity's conditions narrow its rows after `where_in`, a list as `= ANY`; `by: :id`
   groups by the entity's `<aggregate>_id`; neither joins.
5. **Order.** Groups come back ordered by the stored key, NULL last: a `one_of:` value or
   a state alphabetically, not in declaration order.
6. **A sum past its type raises.** `to_i32` on an `Int32` column raises `OverflowError`,
   `to_i64` past `Int64` raises `ArgumentError`, and a decimal value refuses a total past
   its precision; none is caught.
7. **Not provided.** A `groups` that adds up an entity's attribute groups by no attribute
   of the aggregate but its id (narrow with `where:` instead); several `by:` keys; a count
   per group; a condition on a referenced aggregate's attribute; an expression or a derived
   value in `of:`; a condition on the totals; a condition on a list of entities in a
   `finds` or `counts`; `of:` on an entity below the first level.

## Reasons

- A total is the first read a report asks for, and it belongs beside `finds` and `counts`
  with the same `where:`, so the tenant predicate and the removed rows are handled once,
  by the query, not by every report.
- Text keeps a PostgreSQL sum exact without a Crystal type per column pair: `sum(int)` is a
  `bigint`, `sum(bigint)` and `sum(numeric)` are `numeric`, and only the caller knows which
  value to build.
- A bound that a sum can break would make a declared query raise on data it was declared
  for; refusing the declaration keeps a `sums` total.
- Conditions on an entity's rows go under the list's name: Crystal reads `{lines:
  {segment: s}}` as a named tuple and does not parse `{Line.segment: s}`, and the name is
  the one `has lines : Array(Line)` gives.
- An entity's row holds its aggregate's id, so a total per aggregate needs no join; the
  rejection below stands for every other aggregate attribute.
- A report that reaches another aggregate's attribute, such as an account's kind, asks
  that aggregate's query for the ids and passes them as a list: a statement reads one
  aggregate's rows.
- A sum is linear: the total of `credit - debit` is the total of `credit` less that of
  `debit`, exactly. A `groups` returns each key once in key order, so its keys are the
  distinct list, and a condition on totals is a `select` over its rows.

Rejected:

- **SQL in a declared read.** ADR 0035 keeps SQL out of rules; `where_in` says the join
  without naming a table or a column.
- **Typed SugarORM sums.** An overload per column type and per key type, when one text
  terminal and one conversion per declaration do the same.
- **Grouping an entity sum by an aggregate attribute.** It needs a join in the group key; a
  `where:` on the aggregate attribute reads the same total.
- **Conditions written `Line.segment:`.** Crystal does not parse them.
- **A join through a reference, `Line.account.kind`.** It reads another aggregate's
  columns, which `Rows` keeps private ([ADR 0030](0030-sweettalk-domain-language.md)
  decision 4).
- **`of:` an expression or a derived value.** It states a Crystal expression again in SQL
  ([ADR 0035](0035-sweettalk-specifications-queries-and-state-checks.md)).
- **A `distinct` word and `having:`.** Each is a `groups` read another way.
