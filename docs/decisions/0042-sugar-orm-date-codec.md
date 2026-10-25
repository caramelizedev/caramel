# ADR 0042: SugarORM stores a calendar date in a PostgreSQL `date` column

Date: 2026-10-24

Status: accepted. Amends [ADR 0007](0007-sugarorm-schemas-changesets-preload.md) decision 1.

## Context

A codec could name only `numeric`, `numeric(P,S)`, `jsonb` or `text`, so an application that
needed a calendar day, a due date or a birthday kept it as validated text: a regular
expression `CHECK`, a string in the model, and no range query. Crystal has no date type
without a clock, and a `Time` field is a `timestamptz`, which carries a time of day and a zone
a calendar day does not have.

## Decision

1. **The value.** `SugarORM::Date` is a `struct` with `year`, `month` and `day`, comparable and
   hashable, with no time of day and no zone. Its year runs from 1 to 9999. `Date.new` and
   `Date.parse` raise `ArgumentError` for a day that does not exist, and `Date.parse?` returns
   `nil`. Text is `YYYY-MM-DD` only. It converts to and from a `Time` (`Date.of(time)` reads
   the time's own calendar day; `to_time` is midnight UTC), adds days, names its weekday, and
   is a string in JSON.
2. **The codec.** `SugarORM::DateCodec` encodes a `Date` as `YYYY-MM-DD` and decodes that text.
   `field due_on : SugarORM::Date, codec: SugarORM::DateCodec` is a `date` column. `date` joins
   `numeric`, `numeric(P,S)`, `jsonb` and `text` as a `sql_type` a codec may name. `decode`
   raises `ArgumentError` for `infinity`, `-infinity`, a BC date or any text that is not
   `YYYY-MM-DD`, which is what PostgreSQL's `DateStyle` `SQL`, `Postgres` or `German` would
   print through `"col"::text`; the `ISO` styles always print `YYYY-MM-DD`. An application's
   own calendar type writes its own codec with `sql_type` `date`.
3. **The column type.** `format_type` spells the type `date`, with no modifier, so the
   declared and the live type compare equal as strings. The DDL, the introspection and the
   differ create and compare the column with no other change.

## Reasons

- **A struct, not `Time`.** A `Time` carries a zone, so a day read in one zone and written in
  another moves by one. A `Date` has no zone to disagree about.
- **Strict text.** A date that prints as `24.10.2026`, `infinity` or `0044-03-15 BC` has no
  `Date`, so `decode` says so and names `DateStyle` instead of guessing a day.
- **Rejected:** a `Time` field with a date codec, which hides the zone.
