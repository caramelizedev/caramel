# ADR 0039: SweetTalk optional attributes

Date: 2026-10-24

Status: accepted. Amends [ADR 0031](0031-sweettalk-services-processes-and-richer-values.md)
decision 2.

## Context

`has note : String?` stored a nullable column, but `has owner : Setup::Owner?`,
`has settled_by : Teller?` and `has leg : Money?` did not compile. A model that had an
optional part of any kind of type spelled it as a flag or a type code beside required
columns, and checked in `never` which columns the code allowed. Such an aggregate declared
many attributes and many `never` lines that said only "this set goes together".

## Decision

1. **A type followed by `?` is optional.** `has x : T?` stores `x` in nullable columns and
   its getter returns nil while `x` is not set, for every type `has` takes:
   - a column type: as before;
   - a value, `has settled_by : Teller?`: one nullable column of its raw type;
   - an aggregate, `has owner : Setup::Owner?`: a nullable `owner_id` foreign key, and a
     getter that returns `Setup::Owner::Id?`;
   - an application's schema, `has member : Account?`: the same, and the getter returns a
     `SweetTalk::RecordId(Account)?`;
   - a value with parts, `has leg : Money?`: one nullable column per part.
   An optional attribute starts as nil unless it has a default, so a factory and `create`
   need not set it, wherever the attribute is declared among the others. A projection's or a
   process's key cannot be optional.
2. **A value with parts is set whole or not at all.** The columns of an optional value with
   more than one part carry the check `check_<table>_<attribute>_all_or_none_<hash>`,
   `num_nonnulls(…) IN (0, <parts>)`. The hash is the FNV-1a 32-bit hash of the value's
   part names, sorted and joined by commas, as eight hex digits, computed by the same macro
   that names a lifecycle's and a closed list's check. SugarORM compares an expression check
   by name only, so a part added to the value must change the name for `frappe db diff` to
   replace the constraint. A row that holds only some of the parts, which only a write
   around the domain can leave, is also refused when it is loaded, naming the value. A
   value's own checks, such as a bound or a list, stay on the part's column and pass a NULL.
3. **A command points a reference with its writer.** `self.owner = owner` in a command takes
   the aggregate, the record or its id, and nil for an optional attribute. The writer is
   private to an aggregate, an entity and a process, which change themselves; a
   projection's is public, because its `whenever` handler assigns the row it reads
   (`row.last_transfer = settled.transfer_id`). `@owner = owner` would only declare an
   unrelated instance variable, since the reference is stored in `@owner_id`, so a `to` or a
   `factory` that assigns it does not compile, and the message names `self.owner =`.
4. **Entities, projections and processes take the same attributes.** Their constructors
   accept `owner : Owner | Owner::Id | Nil`, and an entity's facts in an event carry them
   as null.
5. **Reading them.** `where: {owner: nil}`, `{settled_by: nil}` and `{leg: nil}` in
   `finds`, `counts` and `specification` ask for the rows where it is not set, in Crystal
   and in PostgreSQL alike; a value with parts is asked as a whole, with nil or a value.
   nil is accepted only for an optional attribute: for a required one the query does not
   compile, naming the attribute, because it could never match (a scalar) or would call a
   method on nil (a value with parts). A variable that may be nil is refused as SugarORM
   refuses it in `where`: it would match the rows whose column is NULL whenever it was nil.
   `order:` takes an optional attribute stored in one column; PostgreSQL sorts NULL first
   in `:desc` and last in `:asc`.
6. **A factory builds by name.** `create` and a factory both build the aggregate from
   keyword arguments, in which an optional attribute or one with a default may be left out
   wherever it is declared. A positional constructor cannot give a default to a parameter
   that a required one follows, so a factory that took the optional parameter first failed
   to compile.

7. **An optional attribute now defaults to nil, which is a change of behaviour.** Before, a
   factory that did not set `has note : String?` failed with "factory does not set note"; now
   it leaves it nil, and code that relied on the error to learn it forgot a field no longer
   gets it.
8. **The new constraints can stop `frappe migrate`.** `frappe db diff` adds the checks and a
   new foreign key `NOT VALID`, and validates them in a later step. Rows written before them
   that break one stop `frappe migrate`, which leaves the constraint `NOT VALID` (it refuses
   new rows, not old ones) until those rows are fixed. Before migrating, find them:
   - an optional value with parts that is set in some of its columns:
     `SELECT id FROM <table> WHERE num_nonnulls("<attr>_<part>", …) NOT IN (0, <parts>)`;
   - a foreign key added to a column that held ids: `SELECT t.id FROM <table> t LEFT JOIN
     <target> o ON o.id = t."<attr>_id" WHERE t."<attr>_id" IS NOT NULL AND o.id IS NULL`;
   - a value's own bound, length or list (ADR 0035 and 0040) on a column that did not have
     it: the same condition negated, `WHERE "<column>" NOT BETWEEN <lo> AND <hi>` or
     `NOT IN (…)`, keeping the rows that are NULL.
   Adding a part to a value changes a check's name, so the old one is dropped and the new
   one added and validated the same way.
9. **When not to use `?`.** An optional attribute is one the thing may lack. A column that is
   present only for some kinds of the thing is another concept: group it in a value with
   parts, which is set whole or not at all, or give the aggregate a state that holds it. A
   rule that ties one attribute's presence to another, as in "a refund has a reason", stays
   a `never`: `?` says an attribute may be absent, not when.

## Reasons

- The word "optional" already means nil in Crystal's types. Another word would make the
  reader learn that `String?` and `Teller?` differ.
- One nullable group of columns plus one check says "all or none" once. The alternative,
  an attribute per part with a `never` on each pair, is what the domain repeated by hand,
  and PostgreSQL could not enforce it.
- A half-set value cannot be built in Crystal, because its type needs every part. The
  check and the load refusal cover the writes that do not go through Crystal.
- A writer is needed because a nilable reference otherwise has no way to change: commands
  reach attributes by their instance variables, and a reference's variable is `@owner_id`,
  of another type than the attribute.
- Foreign keys stay `ON DELETE` as `belongs_to` makes them; SugarORM derives a nullable
  key from `belongs_to owner : Row?`, so `frappe db diff` writes the nullable column, its
  key and its index.

Rejected:

- **A sentinel value, such as an empty text or an owner with id 0.** Every reader would
  check for it, and a foreign key cannot hold it.
- **A union `has x : T | Other`.** It is a type code in disguise, the thing optional
  attributes are to replace; each such case should be a variant of its own.
- **A child table for an optional value with parts.** It adds a join to every read for one
  group of columns, and the aggregate already owns them.
