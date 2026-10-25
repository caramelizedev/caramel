# ADR 0040: SweetTalk closed-set string values

Date: 2026-10-24

Status: accepted. Amends [ADR 0031](0031-sweettalk-services-processes-and-richer-values.md)
decision 1.

## Context

A closed vocabulary, such as the kinds of a transfer, was written four to six times: a list
constant, a regular expression of the same words, a predicate for each member in Crystal,
a `length:` range that fits the longest word, and a SQL list when it was checked at all.
The copies drift, and the regular expression was only checked in Crystal.

## Decision

1. **`value Kind, String, one_of: %w[payment receipt], means: "…"`** is a string value
   whose text is one of the words. The list is written once, as literal words that start
   with a letter and hold letters, digits and underscores. It takes neither `matches:` nor
   `length:`, and a list that is not a literal, is empty, repeats a word or lists a word
   that does not compile as a method name does not compile.
2. **Crystal checks it when the value is built, loaded or bound.** A text outside the list
   refuses with `Kind must be one of payment, receipt`, which a contract field shows as its
   error.
3. **PostgreSQL checks it too.** Every column that stores the value gets
   `check_<table>_<column>_one_of_<hash>`, `"column" IN ('payment', 'receipt')`. The hash is
   the FNV-1a 32-bit hash of the words, sorted and joined by commas, as eight hex digits,
   as a lifecycle's check has, from the same macro, so a changed list is a new constraint.
   `database_check: false` keeps the list in Crystal only; a name over 63 bytes does not
   compile, as for a bound. A NULL passes the check, so an optional value of the list
   (`has channel : Channel?`, ADR 0039) is held to the list or to NULL.
4. **The words become methods.** `Kind.all` returns every member in the order listed,
   `Kind.includes?(text)` asks about a text, `Kind.receipt` builds a member, and
   `kind.receipt?` asks. A word that names a method the value already has, such as `all`, a
   method every class or object has, such as `name`, `hash`, `class`, `inspect`, `to_s`,
   `nil` or `tap`, or a Crystal keyword, does not compile. Words with capitals map to
   `underscore`d names, so `USD` gives `usd?`.
5. **The list is a constant.** `Kind::SWEETTALK_ONE_OF` holds the words, for tools that
   read the model; domain code reads `Kind.all`.

6. **The new constraint can stop `frappe migrate`.** `frappe db diff` adds
   `check_<table>_<column>_one_of_<hash>` `NOT VALID` and validates it in a later step. A row
   that holds a text outside the list stops `frappe migrate`, which leaves the constraint
   `NOT VALID`, refusing new rows only, until the row is fixed. Before migrating, find those
   rows, one query for each column that will store the value:
   `SELECT id, "kind" FROM counter_transfers WHERE "kind" IS NOT NULL AND "kind" NOT IN
   ('payment', 'receipt', 'net_settlement')`. Adding a word to the list, or removing one,
   changes the hash, so the old check is dropped and a new one is added and validated the
   same way; removing a word needs the rows that hold it changed first.

## Reasons

- A single list read three ways, by Crystal, by PostgreSQL and by predicates, cannot
  disagree. The check is exact, unlike a pattern, so ADR 0035's reason for keeping
  patterns in Crystal, that PostgreSQL reads them differently, does not apply.
- Predicates replace `kind == "receipt"`, a string compared by hand at every use, with a
  method that fails to compile when the word is misspelled.
- Hashing the list into the name follows ADR 0035: SugarORM compares an expression check by
  name, so a changed list must change the name for `frappe db diff` to replace it.
- A value, not an enum type, because the stored form stays text, which is what existing
  columns hold, and the list stays a CHECK that a later release can change. A PostgreSQL
  enum type cannot drop a value.

Rejected:

- **Groups of words, as in `trade: %w[receipt vendor_payment]`.** A subset is a rule over
  the value, so it belongs to a method or a specification on the aggregate that holds it.
- **A Crystal `enum`.** It would store numbers or need its own column mapping, and the
  words in existing data would not map.
