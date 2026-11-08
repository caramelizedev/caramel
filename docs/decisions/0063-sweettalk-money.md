# ADR 0063: SweetTalk money

Date: 2026-11-07

Status: accepted. A module under [ADR 0061](0061-sweettalk-modules.md).
Amends [ADR 0047](0047-sweettalk-decimal-and-json-values.md) (Rejected, integer minor units)
and [ADR 0040](0040-sweettalk-closed-set-values.md) decision 4. Decision 10 amends
[ADR 0049](0049-sweettalk-sums-and-groups.md) decisions 2 and 3.

## Context

An amount whose currency is chosen per row was two attributes paired by convention: a
`Cents` value beside a `Currency` value. Adding amounts in two currencies compiled and
returned a wrong number, any three capitals were stored, text was rounded silently on
parse, and a conversion checked the amount's currency against the rate's at run time,
through strings. A Crystal generic argument is a type or a number, never a string, so a
currency in a type needs a type per currency.

## Decision

1. **`require "caramel/sweet_talk/money"` is the module.** It requires
   `caramel/sweet_talk/decimal`. `currencies`, `quote` and `allocation` without it fail
   compilation naming the require, from stubs the core defines and the module redefines,
   and a program without it holds none of its code.
2. **`currencies %w[USD EUR JPY], exponent: {XAU: 4}, means: "…"`** in a context or a
   kernel, once, declares `Currency`: a closed set of three-capital codes, checked when it
   is built and by `check_<table>_<column>_one_of_<hash>` on every column that stores it,
   as ADR 0040's are. `Currency.all`, `includes?`, `Currency.usd`, `usd?` and `exponent`
   are its methods. A code whose methods would hide ones every value or object has, such
   as ALL (`all`) and TRY (`try`), gets no `Currency.all`-style methods; `Currency.new`
   builds it. Each code is also a marker type, `Currency::USD`, with `CODE` and `EXPONENT`.
3. **Minor units come from ISO 4217 list one**, published 2026-09-17 and fetched on
   2026-11-07 from
   <https://www.six-group.com/dam/download/financial-information/data-center/iso-currrency/lists/list-one.xml>:
   165 codes with 0 to 4 minor units and 13 marked N.A., embedded as Crystal literals in
   `money/iso4217.cr`. A code outside the list, or marked N.A., takes `exponent:`, 0 to 9;
   one the list gives, or a code `exponent:` names that is not listed, fails compilation.
4. **`Minor(Currency::USD)` is a signed `Int64` count of minor units.** `+`, `-` and `<=>`
   take the same `Minor` only, `*` an integer; no integer is added to it. `Minor(USD) +
   Minor(EUR)` fails in Crystal's overload resolution, at the caller's line, naming both
   types. `parse(text)` refuses more decimals than the currency keeps (`USD keeps 2
   decimals, not 12.345`) and `round(text, rounding:)` rounds on purpose. `text` is
   `12.30` and `to_s` `12.30 USD`.
5. **`Amount` is the union of every member's `Minor`**, the type of an amount whose
   currency is data. Two `Amount`s added fail compilation. `same(a, b) { |x, y| … }` is a
   macro with one branch per currency that runs the block on two amounts of one currency
   and refuses two (`An amount in EUR and one in USD cannot be combined`); `by_currency`
   totals each currency. `Amounts.new(currency:, raw:)`, `Amounts.parse` and
   `Amounts.round` build the member a currency names.
6. **Every stored amount carries its currency.** `has original : Money::Amount` stores
   `original_currency` under the currencies' CHECK and `original` as `bigint`, loaded
   through `Amounts`; an optional amount stores both or neither, under
   `check_<table>_<name>_all_or_none`. `has fee : Minor(Currency::USD)` stores the same two
   columns and refuses another currency when it loads. `has` and event fields find the
   loader through `SWEETTALK_LOADER` on the marker type. An event carries
   `{"currency": "USD", "raw": 1230}`, and `finds` and `specification` compare both columns.
7. **`quote Rate, rounding: :half_up, means: "…"`** declares `RateDay`, a day, and `Rate`,
   a value with parts stored one column each: `from` and `to`, two different currencies,
   `numerator` and `denominator`, the fraction in lowest terms and above zero, `day` and
   `source`. `Rate.parse("1.0851", from:, to:, day:, source:)` reads it exactly and
   `Rate.of(BigRational, …)` refuses a fraction past `Int64`. `amount.convert(rate)`
   returns the amount in `to`, rounded `:half_up`, `:half_even`, `:down` or `:up` as the
   quote declares, and refuses an amount in another currency than `from`. `inverse` and
   `through(other)` are exact cross rates; `through` joins rates of one day, and their
   sources. A rate's window, a fallback and an override are the application's.
8. **`allocation split, of: Money::Amount, by: Weight, remainder: :largest_fraction,
   means: "…"`** declares an [ADR 0062](0062-sweettalk-calculations.md) calculation,
   `split(total, weights : Hash(Int64, Weight))`, keyed by `per:` when given. Each key gets
   the floor of its exact share, a `BigRational`; the units left go one each to the
   largest fractions (`:largest_fraction`), all to the first or last key of weight above
   zero (`:first`, `:last`), or all to a third argument (`:to`). Ties go by key, smaller
   first; `ties:` takes only `:key`. A negative weight, weights summing to zero, or a `:to`
   key without weight refuses. Generated rules on `result` say the parts sum to the total
   in its currency, each is the floor or ceiling of its share (the floor, but the receiving
   key's, for the other modes), and a zero weight gets zero; `Corretto.property` draws
   hashes and amounts to run them. `Float64`, `to_f` or a float literal in its types or
   block fails compilation at that line.
9. **Checks.** Each refusal has a fixture in `sweet-talk-compilation`, which also builds
   `spec/fixtures/sweet_talk/money.cr` to prove decision 1 on the binary, and
   `spec/sweet_talk` runs amounts, rates and allocations on PostgreSQL with the other
   modules, and catches a split seeded one unit short within 200 drawn cases.
10. **`sums` and `groups` add up amounts** (amends ADR 0049 decisions 2 and 3). A
    `Minor(Currency::USD)` adds up as a number: `sums` returns one, zero when nothing
    matches, and `groups` one per key. A `sums` of an `Amount` returns `Hash(Currency,
    Amount)` in one statement grouped by `<name>_currency`: a total per currency that has
    rows, in code order, as `by_currency` totals loaded amounts, `{}` when nothing matches;
    an optional amount's unset rows add nothing. A `groups` that adds up an `Amount` does
    not compile. `by:` an amount groups by its currency, as `{by: Currency, total: …}`.

## Reasons

- **Marker types keep the mix a type error.** Crystal reports `Minor(USD) + Minor(EUR)`
  at the caller's line with both types, so no macro needs the receiver's type (ADR 0046's
  limit) and no error points into generated code. ADR 0040's reason against an `enum`
  stands: a marker stores nothing, and the column keeps the code as text.
- **`same` is a macro.** A block given to a method called on a union is typed once for
  every member, so its arguments become unions again; a branch per currency keeps each
  block's arguments one type, and errors in the block point at its line.
- **A rate's currencies are data.** Rates are stored and loaded like amounts, so a typed
  `Rate(A, B)` would need a union of every pair of currencies; `convert` checks the
  amount against `from` instead, and the result is an `Amount`.
- **Refuse excess decimals.** A third decimal on a dollar is a mistake in the caller's
  data, as a ninth on a `Decimal(20, 8)` is (ADR 0047); an import rounds by saying how.
- **One load path.** A currency column beside every amount, under a CHECK, holds for a
  reporting currency too, so no amount reads its currency from the tenant or a setting.
- **An allocation is a calculation.** Its identity, that the parts sum to the total, is a
  rule on `result` that every call checks and `Corretto.property` draws cases against, so
  a hand-written split one unit short fails within 200 cases. Ties by key make the result
  one function of its arguments, and refusing floats at the author's line keeps the shares
  exact.
- **A total of amounts is per currency.** Adding `original` without its currency adds
  euros to yen; grouping by the currency column keeps them apart, and `Hash(Currency,
  Amount)` is the shape `by_currency` answers.

Rejected:

- **An `Amount` composite whose `+` refuses a mismatch at run time.** It compiles the
  mix the type refuses.
- **A role parameter, `Minor(Reporting)`, resolved per tenant.** A second load path, and
  a column that says nothing alone.
- **`Float64` and rounding on parse.** A float drifts, and silent rounding hides the
  mistake the refusal names.
- **A tie broken at random, or by insertion order.** The same weights would split two
  ways, and a property case could not be replayed from its seed.
- **`Array(Amount)` for a sum of amounts.** A lookup by currency would scan it.
- **`by: Line.original.currency`.** An amount's one key is its currency, and an
  aggregate's own amount would need another form.
