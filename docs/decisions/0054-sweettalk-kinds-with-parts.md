# ADR 0054: SweetTalk kinds with parts

Date: 2026-11-07

Status: accepted. Amends [ADR 0039](0039-sweettalk-optional-attributes.md) decision 9.

## Context

A transfer that is a payment has a payee, and one that is a receipt has none. SweetTalk
stored each such attribute as optional and left the tie to a `never` in Crystal, so a row
written around SweetTalk could hold a receipt with a payee, and each rule was written once
per attribute and kind (#262).

## Decision

1. **`has kind : Kind, parts: {payment: [payee], net_settlement: [payee, leg]}`** ties
   optional attributes to the members of a closed-set value. `parts:` goes on a required
   value with `one_of:`, in an aggregate or an entity. Each key is a member, underscored,
   and lists attributes declared above, each optional and none a list of entities, each
   named once under its member. A member `parts:` omits, such as `receipt`, holds none of
   the attributes any member lists.
2. **One CHECK per member of the value, listed or not.** `"kind" <> 'payment' OR
   (num_nulls(<set columns>) = 0 AND num_nonnulls(<unset columns>) = 0)`, with the columns
   of a reference, a part of a value with parts, or the attribute; a conjunct with no
   columns is dropped. It is named `check_<table>_<attribute>_<member>_<hash>`, as every
   declared check is, and a violation refuses with the sentence.
3. **The same rule in Crystal.** A generated `never` refuses before a save with "Settlement
   kind payment holds payee and no leg": the member, what it holds, then what it lacks. A
   member with nothing listed reads "holds no payee or leg".
4. **A reader per listed member.** `as_payment` returns `{payee: Owner::Id}`, each part
   without its `?`, and raises `TypeCastError` for any other member. `parts:` that names a
   method the aggregate already has, `as_payment`, does not compile.
5. **Refusals at compilation.** `parts:` on a projection or a process, on anything but a
   required closed-set value, anything but a non-empty `{member: [attribute, …]}`, a key
   that is no member, an attribute not declared above, a list of entities, a required
   attribute, or one attribute twice under a member.
6. **A new check can stop `frappe migrate`.** As ADR 0039 decision 8 says of a check
   added to a table that holds rows, it is added `NOT VALID` and validated later. Find the
   rows that break one first: `SELECT id FROM <table> WHERE NOT (<sql>)`, with the SQL
   of decision 2.

## Reasons

- The members and the attributes they hold are one fact; saying it at the value's
  attribute keeps it in one place, and the database keeps it whoever writes the row.
- A CHECK for the members `parts:` omits matters as much: a receipt holds no payee, and
  the rule that says so is the one most often forgotten.
- The sentence is what the user reads in Crystal and in a database refusal, so it names
  what the member holds and lacks.

Rejected:

- **A state that holds the columns.** ADR 0039 names it, and it ties a lifecycle to a
  value that is not one.
- **A `never` per kind.** It cannot be a CHECK, and each author writes it again.
