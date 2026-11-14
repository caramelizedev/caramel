# ADR 0063: Money is an opt-in SweetTalk module that counts minor units in a type per currency

Date: 2026-11-07

Status: accepted.

## Context

An amount whose currency is chosen per row was two attributes paired by convention: a count of cents beside a currency. Adding amounts in two currencies compiled and returned a wrong number, any three capitals were stored, text was rounded silently on parse, and a conversion checked currencies at run time, through strings. A Crystal generic argument is a type or a number, never a string, so a currency in a type needs a type per currency.

## Decision

1. **Money is a module behind its own require.** It follows the modules rule of [ADR 0030](0030-scope-and-modules.md): a program without the require holds none of its code, and a money word used without it fails compilation naming the require. The words are in `site#c-sweettalk-money`.
2. **The application declares its currencies once, as a closed set, and each code is also a type.** `Currency` is a closed set like those of [ADR 0040](0040-values.md), checked in Crystal and in PostgreSQL. Each code is also a marker type, `Currency::USD`, that stores nothing. A code whose generated methods would hide ones every object has, such as TRY, gets none instead of failing compilation.
3. **Minor units come from ISO 4217 list one, embedded in the source.** The application states an exponent only for a code the list does not give one for. Overriding a listed code does not compile.
4. **An amount is a signed integer count of minor units, typed by its currency.** `Minor(Currency::USD)` takes only its own currency: adding a `Minor` of another currency is a type error in Crystal, not a run-time check. Decimals stay for numbers with no unit to count in ([ADR 0040](0040-values.md)).
5. **An amount whose currency is data is the union of every currency's `Minor`.** Two such amounts do not add directly. They combine through `same`, a macro with one branch per currency, which refuses two currencies at run time.
6. **Text with more decimals than the currency keeps is refused.** Rounding happens only where the caller asks for it and names the mode.
7. **Every stored amount carries its currency in a column of its own.** This holds for an amount whose type fixes the currency too: it stores the code and refuses another when it loads. No amount reads its currency from the tenant or a setting.
8. **A rate is a stored value whose currencies are data, kept as an exact fraction.** A conversion checks the amount's currency against the rate's at run time and rounds as the rate's declaration says. Cross rates are exact. A rate's window, a fallback and an override are the application's.
9. **An allocation is a calculation that splits an amount by weights, exact to the minor unit.** It is a calculation of [ADR 0035](0035-reads-and-rules.md), so its identities are generated rules that every call checks and `Corretto.property` ([ADR 0010](../0010-corretto.md)) draws cases against. Ties go by key. A float in its types or its block does not compile.
10. **A total of amounts is per currency.** Adding up an amount whose currency is data answers one total for each currency, keyed by currency, and grouping by an amount groups by its currency.

## Reasons

- Marker types make the mix a type error that Crystal reports at the caller's line with both types. No macro needs the receiver's type, which is unknown when a macro expands, and no error points into generated code.
- A marker stores nothing and the column keeps the code as text, so the reason against an `enum` as the stored type ([ADR 0040](0040-values.md)) stands.
- A code whose methods would be taken gets none, since ISO 4217 chose the codes and the application cannot rename them.
- `same` is a macro because a block given to a method called on a union is typed once for every member, so its arguments become unions again. A branch per currency keeps each block's arguments one type, and errors in the block point at its line.
- A rate's currencies are data because rates are stored and loaded like amounts: a typed `Rate(A, B)` would need a union of every pair of currencies.
- A third decimal on a dollar is a mistake in the caller's data, as a decimal past a value's scale is. An import rounds by saying how.
- A currency column beside every amount gives one load path, and a column means something alone.
- An allocation as a calculation makes "the parts sum to the total" a checked rule, so a hand-written split one unit short fails under drawn cases. Ties by key make the result one function of its arguments, and refusing floats keeps the shares exact.
- Adding amounts without their currency adds euros to yen. Grouping by currency keeps them apart, in the same shape a total of loaded amounts has.
- Rejected: an `Amount` composite whose `+` refuses a mismatch at run time. It compiles the mix the type refuses.
- Rejected: a role parameter, `Minor(Reporting)`, resolved per tenant. It is a second load path, and a column that says nothing alone.
- Rejected: `Float64`, and rounding on parse. A float drifts, and silent rounding hides the mistake the refusal names.
- Rejected: a tie broken at random, or by insertion order. The same weights would split two ways, and a property case could not be replayed from its seed.
- Rejected: an array of amounts for a total. A lookup by currency would scan it.
- Rejected: grouping by a path into the amount, such as `Line.original.currency`. An amount's one key is its currency, and an aggregate's own amount would need another form.
