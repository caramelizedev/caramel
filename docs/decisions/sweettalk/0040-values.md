# ADR 0040: A SweetTalk value wraps one raw type or has parts, and checks itself whenever it is built

Date: 2026-10-08

Status: accepted.

## Context

A domain's quantities and words were raw integers and strings: tins could be added to cents, and nothing named what a number meant. A closed vocabulary was written four to six times, in Crystal and in SQL, and the copies drifted; screens branched on its words with a default arm, so a new word fell through in silence. Days were strings, rates were floats and documents were text parsed in Crystal, because no SweetTalk value reached the `date`, `numeric` and `jsonb` codecs of SugarORM ([ADR 0007](../0007-sugarorm.md), [#247](https://github.com/caramelizedev/caramel/issues/247)).

## Decision

1. **A value is immutable and wraps one raw type, or has parts; no other value compiles.** The raw types are an integer, a string, a calendar day, an exact decimal and a JSON document. An array of scalars is refused: a list belongs in a document value or in an entity.
2. **A value checks itself every time it is built, so also when a row is loaded, a contract field binds it or arithmetic returns it.** In a contract field the value's refusal is the field's error.
3. **Arithmetic keeps the value's type, and two different values do not mix.** Multiplying by another value compiles only where the value declares it, and a string value has no arithmetic.
4. **A value with parts equals one of equal parts, and no part is optional by itself.**
5. **A closed set is a string value over one list of literal words, written once.** The column stores the word as text. Crystal and PostgreSQL both check the list, and the constraint's name carries a hash of the list.
6. **The words become methods, and a word that would hide a method does not compile.**
7. **A closed set has a member enum that mirrors its words in memory only.** A screen branches on the member with an exhaustive `case`.
8. **SweetTalk adds no word for labels.** A screen labels each member with a `case` and one catalog message per member ([ADR 0024](../0024-internationalization.md)).
9. **A calendar day is a real day in a `date` column, with no `CHECK`.** A day outside the calendar is refused, not clamped.
10. **There is no `Day.today`.** An application passes its day to the command that needs it, and a day read from a time is that time's own calendar day, with no conversion to UTC.
11. **A decimal is an exact `BigDecimal` in a `numeric(P,S)` column, opt-in by one require.** A program that declares no decimal value links no GMP.
12. **A decimal refuses what its column would round or overflow, and its bounds are decimal text.** It refuses when it is built, so PostgreSQL never rounds or overflows one. The bounds join the constraint's name.
13. **A day and a decimal are text everywhere but in the column.** An event, a job, a projection key and a contract field carry them as strings.
14. **A JSON value is a document kept whole in a `jsonb` column, and a query asks it only for equality or absence.** It has no order.
15. **One constant on the value bridges it to its codec, for every raw type.**

## Reasons

- Tins plus cents is a bug the compiler can catch.
- A single list read three ways, by Crystal, by PostgreSQL and by predicates, cannot disagree. A predicate fails to compile when the word is misspelled; a string compared by hand does not.
- SugarORM compares an expression check by name only, so a list or a bound that is not in the name would never be replaced.
- A closed set stays text in a `CHECK` because that is what existing columns hold and a later release can change the list. A PostgreSQL enum type cannot drop a value.
- Rejected: a Crystal `enum` as the stored type. It would store numbers or need its own column mapping, and the words in existing data would not map; an enum that only mirrors the text in memory needs neither.
- Rejected: groups of words inside the list. A subset is a rule over the value, so it belongs to a method or a specification on the aggregate that holds it.
- Crystal proves a `case … in` exhaustive and refuses its `else`, so a member added to the list fails compilation at every screen that branches on it. A `when` with an `else` sends the new member to the default arm in silence.
- Rejected: a label word, as a meaning per member or a label read from a catalog group named for the value. The first is a second list; the second ties `caramel/i18n` to SweetTalk.
- A day in a `date` column sorts, compares and ranges in PostgreSQL. The column type already refuses a day that does not exist, so a pattern check would say less than the column.
- Rejected: a day that stores text. Text would be permanent API, and every application that adopted it would migrate to `date` later.
- Rejected: `Time` at midnight. It stores a time of day that nothing means and moves by a day when a zone is applied.
- A day outside the calendar, and a decimal the column cannot hold exactly, are mistakes in the caller's data. `numeric` rounds extra decimals in silence.
- A word that reads the clock reads UTC, and a day near midnight is another day in the user's zone. A command that takes the day as an argument is testable and says which zone it means.
- Rejected: optional parts inside a value. The all-or-none check of an optional value covers it as a whole.
- A JSON number is read as a float by most readers, so a decimal travels as a string of plain digits and no reader rounds it.
- Rejected: `Float64` values. A rate of `0.1` is not representable, and a sum of rates drifts.
- Rejected: integer minor units for rates. A rate has no unit to count in; money counts them with its currency beside them ([ADR 0063](0063-money.md)).
- Rejected: bounds as number literals. A fractional literal is a `Float64` in Crystal and would round before it reached the `CHECK`.
- GMP is a link-time dependency, and a program that stores no decimal does not carry it. One require is cheaper than a flag.
- Rejected: linking GMP in `caramel/sweet_talk`. Every application would pay for a value most do not declare.
- PostgreSQL orders `jsonb` by its own rules, which no domain means, so a document has no order.
- Deferred: querying inside a document, a query feature of its own ([#280](https://github.com/caramelizedev/caramel/issues/280)).
- Rejected: one case per raw type. The macros that load, save, bind and compare a value already pass its raw form, so only the field declaration must know a codec.
