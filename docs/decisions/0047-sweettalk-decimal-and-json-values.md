# ADR 0047: SweetTalk decimal and JSON values

Date: 2026-10-28

Status: accepted. Amends [ADR 0031](0031-sweettalk-services-processes-and-richer-values.md)
decision 1, [ADR 0043](0043-sweettalk-calendar-days.md) decision 2 and the
[ADR 0007](0007-sugarorm-schemas-changesets-preload.md) reason on decimals.

## Context

A value wrapped an `Int32`, an `Int64`, a `String` or a `Date`, so `has rate : BigDecimal`
could not be stored, and a financial domain kept a rate as a `Float64` or as a checked
string. Evidence and snapshots were stored as text parsed in Crystal, and not queryable.
SugarORM has a `jsonb` codec, `SugarORM::JSONB(T)`, and the codec contract allows
`numeric(P,S)`, but no decimal codec existed, because ADR 0007 keeps GMP out of an
application that never uses `BigDecimal`. ADR 0043 made `has` reach a value's codec through
one constant, `SWEETTALK_CODEC`, and promised that a `numeric` or `jsonb` value would add
its base to `value` without another change to `has` (#247).

## Decision

1. **`value Rate, Decimal(20, 8), at_least: "0", at_most: "1", means: "…"`** is a decimal
   value: a `BigDecimal` kept in a `numeric(20,8)` column, P digits in all and S after the
   point, with `1 <= P <= 1000` and `S <= P`. `rate.raw` is the `BigDecimal`. It takes
   `at_least:`, `at_most:` and `database_check:`, and no `within:`, `times:`, `matches:`,
   `length:` or `one_of:`.
2. **`SugarORM::DecimalCodec(P, S)`** stores it, in `src/sugar_orm/decimal.cr`:
   `ORDERABLE = true`, `sql_type` is `numeric(P,S)`, `encode` writes plain digits with no
   exponent and no trailing zeros after the point (`-12.5`), and `decode` reads the plain
   digits `numeric::text` prints. `encode` refuses with `ArgumentError` a value with more
   than S decimals or more than P - S digits before the point, so PostgreSQL never rounds
   or overflows one. `SugarORM::Decimal.plain` and `.fits` are the shared words.
3. **Opt-in: `require "caramel/sweet_talk/decimal"`.** That file requires `big`, the codec
   and `caramel/sweet_talk`. Neither `sugar_orm` nor `caramel/sweet_talk` requires it, so a
   program that declares no decimal value links no GMP, as before. A `Decimal(…)` value
   without it fails compilation naming the require.
4. **Bounds are decimal text, checked as CHECKs.** `at_least: "0"` and `at_most: "1.5"` are
   string literals of digits with at most one point. A literal with more than S decimals, or
   more than P - S digits before the point, is refused at compile time, because such a
   bound would never hold on the column. `SWEETTALK_CHECK` is `{"column", suffix, SQL}`,
   `"rate" BETWEEN 0 AND 1`, named `check_<table>_<column>_between_0_and_1` (`from_0`,
   `to_1_5`; `.` becomes `_` and a leading `-` `minus`), so a changed bound is a new
   constraint, as a length's is. `database_check: false` keeps the bounds in Crystal and
   lets them name a constant.
5. **Building a decimal.** `Rate.new("0.05")` reads digits with at most one point and
   refuses other text (`1e-2`, `0,5`, ` 0.5`) with `Rate must be a decimal written with
   digits and a point, as in 12.50`; `Rate.new(BigDecimal)` and `Rate.new(Int)` wrap. Every
   build refuses a value the column would round or overflow (`Rate keeps 8 decimals and 12
   digits before the point, not 0.123456789`), then one outside the bounds (`Rate must be
   at least 0`). `+` and `-` take the same value, `*` an integer, `<=>` and `sort` compare
   by value whatever the scale written, `to_s` is the plain digits and `zero` is `0`.
6. **JSON, events, jobs and contracts carry the text.** A decimal is the JSON string
   `"0.05"`, in an event field, a job payload, a projection key or a `JSON::Serializable`
   type, and is read back by `Rate.new`, so no reader rounds it through a float. A contract
   field binds it from text as a `Caramel::FieldValue(String)`.
7. **`value Evidence, Json(Snapshot), means: "…"`** is a JSON value over a
   `JSON::Serializable` type declared before it, and `value Note, Json, means: "…"` one over
   `JSON::Any`; `evidence.raw` is the document. It is stored in a `jsonb` column through
   `SugarORM::JSONB(T)`, with no bound, pattern, length, list or `database_check:`, so
   `SWEETTALK_CHECK` is nil. `Evidence.new(document)` and `Evidence.parse(text)` build it, it
   equals another with an equal document, and in JSON it is the document itself.
8. **A JSON value is asked only for equality or absence.** `where: {evidence: evidence}` and
   `where: {evidence: nil}` in `finds`, `counts` and `specification` compare the whole
   document; a Range fails compilation at SugarORM's typed `where`, and `order:` on one is
   refused by the context, because a document has no order. Querying inside the document
   (`@>`, GIN) waits on #133.
9. **`has` stores both through the one bridge** of ADR 0043 decision 2: `field rate :
   ::BigDecimal, codec: ::SugarORM::DecimalCodec(20, 8)` and `field evidence :
   ::Snapshot, codec: ::SugarORM::JSONB(::Snapshot)`, `?` after the type for an optional
   one. A projection's or a process's attribute of either type takes no default, as a day
   does not, so it is optional there. `frappe db diff` derives the columns and the checks.
10. **Arrays of scalars stay refused**; a list belongs in a `Json(T)` value whose type holds
    it, or in an entity.

## Reasons

- **A decimal is text everywhere but in the column.** `BigDecimal#to_s` prints an exponent
  past some size, and a JSON number is read as a float by most readers, so the codec and the
  value write their own plain digits and carry them as a string.
- **Refuse at the write, not round.** `numeric(20,8)` rounds a ninth decimal silently and
  raises on a thirteenth digit; a value that cannot be stored exactly is a mistake in the
  caller's data, and the codec says so before PostgreSQL does.
- **The bound joins the name.** The differ compares an expression check by name only, so a
  bound that is not in the name would never be replaced.
- **Opt-in by one require.** ADR 0007's reason holds: GMP is a link-time dependency, and a
  program that stores no decimal should not carry it. One require is cheaper than a flag.
- **Equality only on a document.** PostgreSQL orders `jsonb` by its own rules, which no
  domain means; containment and indexing are a query feature of their own.

Rejected:

- **`Float64` values.** A rate of `0.1` is not representable, and a sum of rates drifts.
- **Integer minor units for rates.** A rate has no unit to count in, and a `Cents` value
  already covers money.
- **Bounds as number literals.** `at_least: 0.1` is a `Float64` in Crystal and would round
  before it reached the CHECK; text keeps the digits the author wrote.
- **A `Json` value with `order:`.** It would sort by `jsonb`'s internal order, which reads
  as random to a domain.
- **Linking GMP in `caramel/sweet_talk`.** Every application would pay for a value most do
  not declare, against ADR 0007.
