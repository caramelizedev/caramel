# ADR 0043: SweetTalk calendar days

Date: 2026-10-25

Status: accepted. Amends [ADR 0031](0031-sweettalk-services-processes-and-richer-values.md)
decision 1 and builds on [ADR 0042](0042-sugar-orm-date-codec.md). Decision 2 is amended by
[ADR 0047](0047-sweettalk-decimal-and-json-values.md).

## Context

A value could wrap only `Int32`, `Int64` or `String`, and `has` stored it as a column of that
raw type. SugarORM stores a calendar day in a `date` column through `SugarORM::DateCodec`
(ADR 0042), but SweetTalk never reached a codec. An application therefore kept a day as a
string value with a pattern, wrote the calendar check again beside it, and read ranges of
days with raw SQL such as `substr(value_date, 1, 7) <= ?`. A first version of this word
stored the day as `YYYY-MM-DD` text; it was withdrawn because text would have become
permanent API, and a `date` column cannot be reached from it without a migration.

## Decision

1. **`value Day, Date, means: "a calendar day"`** is a value that is a real calendar day, from
   year 1 to 9999. `Date` names what the value wraps, as `String` does, and means
   `SugarORM::Date`. It takes no bound, pattern, length or list, and `database_check:` has
   nothing to keep, so it is refused. `day.raw` is the `SugarORM::Date`, so the raw type of a
   `Day` is not a `String`.
2. **The `has`-to-codec bridge is one constant.** Every value records `SWEETTALK_WRAPS`, the
   name of its raw type, and `SWEETTALK_CODEC`, the codec that stores it, or `nil`. `has`
   writes `field settled_on : ::SugarORM::Date, codec: ::SugarORM::DateCodec` for a value with
   a codec, with `?` after the type for an optional one, and `param` takes the raw type. The
   bridge is general: any value that names a codec is stored through it, and a later `numeric`
   or `jsonb` value adds its base to `value` without another change to `has`. `Decimal(P, S)`
   over `SugarORM::DecimalCodec(P, S)` and `Json(T)` over `SugarORM::JSONB(T)` did so in
   [ADR 0047](0047-sweettalk-decimal-and-json-values.md), with no change to this bridge.
3. **The column is `date`.** The table derivation gives a `date` column, and for a table that
   holds the day as `text` the differ derives ADR 0042's checked retype. There is no `CHECK`:
   the type makes PostgreSQL refuse a day that does not exist, and `SWEETTALK_CHECK` is `nil`.
4. **Loading and saving carry the raw type.** A row's reader returns a `SugarORM::Date`,
   which `Day.new` wraps; a save writes `day.raw`. The load and save tuples, a projection's
   key and an entity's columns already go through `raw`, so they need no case for a type
   that is not a `String`.
5. **A part may be a `Day`.** `part came_back : Day` inside a value with parts stores one
   `date` column for it; the part tuple records the codec. A part cannot be optional, as
   before. An optional value that has parts and a `Day` part keeps its all-or-none check.
6. **Queries read it as a day.** `finds in_month(from : Day, to : Day), where:
   {settled_on: from..to}` takes a closed, beginless or endless `Range` of days through the
   codec's `ORDERABLE`, `order: {settled_on: :desc}` sorts the column, and `counts` and a
   `specification` with `where: {settled_on: a..b}` compare days in Crystal and in
   PostgreSQL alike. A specification binds a day through the row's own encoder for the
   column, so it is the same `YYYY-MM-DD` text that `finds` binds.
7. **Events, jobs and JSON carry the ISO text.** A `Day` in an event field (`carries:` or
   declared), a job payload or a projection key is written as `"2026-03-01"` and read back
   by `Day.new`. A `Day` is also a JSON string in a `JSON::Serializable` type.
8. **A contract field binds a `Day` from `YYYY-MM-DD`** as a `Caramel::FieldValue(String)`;
   the value's refusal sentence is the field's error.
9. **The words.** `Day.new("2026-02-30")` refuses with `Day must be a calendar day written
   YYYY-MM-DD, as in 2026-02-28`; `Day.new(2026, 3, 1)`; `Day.of(time)` reads the time's own
   calendar day, with no conversion to UTC; `day + 7`, `day - 7` and `day - other` (an
   `Int32` count of days); `<=>` and `sort`; `year`, `month`, `day`, `to_s` as `YYYY-MM-DD`,
   and `to_time`, midnight UTC. A result outside years 1 to 9999 refuses.
10. **There is no `Day.today`.** An application passes its day to the command that needs it.

## Reasons

- **The codec is already the stored form.** The day then sorts, compares and ranges in
  PostgreSQL as a `date`, so a month of days is a range, not a `substr`.
- **One constant, not one case per base.** The macros that load, save, bind and compare a
  value already pass its `raw`; the only place that must know a codec is the `field` line,
  and the places that bind a value without SugarORM's typed `where`, the specification's
  conditions. A general mechanism cost no more than a `Date`-only one.
- **No `CHECK`.** ADR 0042 explains why the column type already refuses a day that does not
  exist, so a regular expression would say less than the column.
- **Refuse, do not clamp.** A day outside the calendar is a mistake in the caller's data.
- **No `today`.** A word that reads the clock reads UTC, and a day near midnight is another
  day in the user's zone. A command that takes the day as an argument is testable and says
  which zone it means, and `Day.of(time)` reads the zone the time carries.

Rejected:

- **A `Day` that stores text.** Its `raw` would be text for good, and every application
  that adopted it would migrate to `date` later.
- **`Time` at midnight.** It stores a time of day that nothing means and moves by a day when
  a zone is applied.
- **Optional parts inside a value.** The all-or-none check of an optional value covers it as
  a whole, and a part that is optional alone is a change of its own.
