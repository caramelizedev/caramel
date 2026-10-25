# ADR 0042: SugarORM stores a calendar date in a PostgreSQL `date` column

Date: 2026-10-24

Status: accepted. Amends [ADR 0007](0007-sugarorm-schemas-changesets-preload.md) decision 1.

## Context

A codec could name only `numeric`, `numeric(P,S)`, `jsonb` or `text`, so an application that
needed a calendar day, a due date or a birthday kept it as validated text: a regular
expression `CHECK`, a string in the model, and no range query, because a codec column took
only a value or `nil` in `where`. Crystal has no date type without a clock, and a `Time`
field is a `timestamptz`, which carries a time of day and a zone a calendar day does not have.

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
4. **Ranges.** A codec declares `ORDERABLE = true` when its column orders the way its values
   do. Keyword `where` then takes a closed, beginless or endless `Range` of the field's type
   (`due_on: first..last`, `due_on: first...next_first`, `due_on: first..`) on that column,
   and `SugarORM::DateCodec` declares it. A codec without the constant, or with it `false`,
   such as the numeric, `jsonb` and `text` codecs, still takes only a value or `nil`, and a
   Range fails compilation. No codec takes an Array. `order_by` takes every field and never
   needed the constant. The codec must be defined before the schema that names it, or the
   schema cannot read the constant and refuses ranges.
5. **Text to date.** When a field is declared `date` and the live column is `text`, the
   differ derives the change instead of halting, with or without `--dev-override`. The
   transactional migration holds these statements, in order:
   - a `DO` block that locks the table, counts the rows whose text is not a calendar day
     written `YYYY-MM-DD` (a `NULL` passes), and raises with that count and up to five
     distinct values, each cut to 40 characters, when there are any; the migration rolls back
     and changes nothing;
   - `DROP DEFAULT`, when the text column has one;
   - `ALTER TABLE … ALTER COLUMN … TYPE date USING "col"::date`.

   A `CHECK` on the table that no schema declares is dropped before all of them, as the
   differ already orders it, and the diff prints a note that the change rewrites the table
   under an exclusive lock. The check runs in the migration, so each environment checks its
   own rows.
6. **Every other type change** keeps its halt. In particular `date` to `text` halts, and
   `--dev-override` alters it in development only.

## Reasons

- **A struct, not `Time`.** A `Time` carries a zone, so a day read in one zone and written in
  another moves by one. A `Date` has no zone to disagree about.
- **A constant, not a method.** `where` is checked at compile time, and a macro can read a
  constant's value but cannot call a method. A codec opts in by writing the constant.
- **Opt-in ranges.** A numeric codec's values are text in Crystal and numbers in SQL, and
  `text` compares by the database's collation, so a range there would answer by rules the
  application did not choose. A `date` compares the same way in both. Binding the encoded
  `YYYY-MM-DD` text lets PostgreSQL read it as a `date`, so the comparison is by day.
- **Strict text.** A date that prints as `24.10.2026`, `infinity` or `0044-03-15 BC` has no
  `Date`, so `decode` says so and names `DateStyle` instead of guessing a day. On the way in,
  `'10/11/2026'` casts to a different day under each `DateStyle`, `'today'` is a different day
  on each run and `'infinity'` has no `Date`. Requiring `YYYY-MM-DD` and
  `pg_input_is_valid` (PostgreSQL 16 and later; the block raises a clear error on an older
  server) reports each of them as a row instead of changing it.
- **The check in the migration.** `frappe db diff` sees only a scratch branch of the
  development database, not the rows a deploy will meet. Locking first means no row arrives
  between the check and the rewrite.
- **Rejected:** a `Time` field with a date codec, which hides the zone; deriving text to date
  with no check, which stops at the first bad value and does not count the rest; and halting
  every text to date change, which sends every application through add, backfill and drop for
  a change the check makes safe.
