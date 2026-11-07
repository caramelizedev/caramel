# ADR 0063: SweetTalk money

Date: 2026-11-07

Status: accepted. A module under [ADR 0061](0061-sweettalk-modules.md).
Amends [ADR 0047](0047-sweettalk-decimal-and-json-values.md) (Rejected, integer minor units)
and [ADR 0040](0040-sweettalk-closed-set-values.md) decision 4.

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
8. **Checks.** Each refusal has a fixture in `sweet-talk-compilation`, which also builds
   `spec/fixtures/sweet_talk/money.cr` to prove decision 1 on the binary, and
   `spec/sweet_talk` runs amounts and rates on PostgreSQL with the other modules.

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

Rejected:

- **An `Amount` composite whose `+` refuses a mismatch at run time.** It compiles the
  mix the type refuses.
- **A role parameter, `Minor(Reporting)`, resolved per tenant.** A second load path, and
  a column that says nothing alone.
- **`Float64` and rounding on parse.** A float drifts, and silent rounding hides the
  mistake the refusal names.
