# ADR 0039: A SweetTalk aggregate is a SugarORM schema that is its own repository, and PostgreSQL keeps the rules a row alone decides

Date: 2026-10-08

Status: accepted.

## Context

A domain needs a root with an identity, the things it owns, the states it passes through and the rules every change keeps. Models spelled an optional part as a flag, tied a kind's attributes to it with one hand-written `never` each ([#262](https://github.com/caramelizedev/caramel/issues/262)), and flattened an entity's own list onto the aggregate ([#250](https://github.com/caramelizedev/caramel/issues/250)). A write around SweetTalk skipped every check made in Crystal, and uniqueness needed a table of claims and a read under a lock ([#166](https://github.com/caramelizedev/caramel/issues/166)).

## Decision

1. **Aggregates, entities and projections are SugarORM schemas, written only through their changesets.** The migrations are derived from the declarations ([ADR 0008](../0008-migrations.md)).
2. **An aggregate is a root with a typed id and is its own repository.**
3. **`has` chooses the storage from the type, and `the` is never stored.** A value with parts is one column per part, another aggregate is a foreign key read as an id, and a list of entities is a child table.
4. **A type followed by `?` is optional, for every type `has` takes.** An optional attribute reads as nil while it is not set. It says the thing may lack the attribute, not when.
5. **A command points a reference through a private writer.**
6. **Aggregates and entities are built by name.** An optional attribute may be left out wherever it is declared.
7. **`parts:` ties optional attributes to the members of a closed-set value.** The attribute that holds the kind lists what each member holds; a member it omits holds none of them. The one declaration gives the invariant in Crystal and a database check per member.
8. **An entity is stored with its parent, at any depth.** A list inside an entity takes the same word and the same rules as a list inside an aggregate. Loading is one statement per list per level. An entity another parent holds is inserted anew.
9. **A save deletes dropped children itself, before it writes.** The foreign keys do not cascade and the unique indexes are not deferrable.
10. **A lifecycle is chains of states with private movers and a public graph.** Only a command moves the state; a screen reads the graph to decide what to offer.
11. **`never` and `always` hold after every command, at every depth.**
12. **`remove` retires an aggregate and keeps its row.** Its unique values stay reserved.
13. **A factory replaces `create`.**
14. **The rules a row alone decides are PostgreSQL constraints.** A value's bounds and length, a lifecycle's states, the all-or-none of an optional value with parts and a kind's parts are CHECK constraints. The state is stored as text, and a pattern is checked in Crystal only. A check's name carries a hash of what it checks, so an edit is a replacement.
15. **An aggregate or an entity declares its own unique indexes, indexes and checks.** A projection and a process take none, and an entity's `unique` holds within its parent.
16. **A violation of a declared constraint is a refusal, mapped by the constraint's name.** A `check` requires its sentence, and a value's bounds take one declared on the value.

## Reasons

- Writes around the changeset would skip the invariants and the value checks made in Crystal. A CHECK holds for every writer: without it, a bad row fails at its next load, far from the write.
- The database is the only place a race cannot pass. A read under a lock is only as safe as the next caller who forgets the lock.
- Rejected: a claims table written in the same transaction. Nothing in the schema says which aggregate it guards; a unit that runs once declares a derived table, which is the claim ([ADR 0046](0046-transactions.md)).
- One column per part keeps each part queryable, with its own CHECK. Rejected: a value with parts as one `jsonb` column. Rejected: a child table for an optional one; it adds a join to every read.
- An entity's identity is its aggregate's: updating the row it was loaded from would move another aggregate's entity. Rejected: a JSON column of children; it loses each entity's id, its key to its parent and its constraints.
- "Optional" already means nil in Crystal's types; another word would make the reader learn that `String?` and `Teller?` differ. Rejected: a sentinel value; every reader would check for it and a foreign key cannot hold it. Rejected: a union `has x : T | Other`; it is a type code in disguise.
- A reference needs a writer because its instance variable holds the id, of another type than the attribute.
- A positional constructor cannot give a default to a parameter that a required one follows. Building by name lifts the order.
- A kind's members and the attributes they hold are one fact, said in one place and kept by the database whoever writes the row. Rejected: a `never` per kind; it cannot be a CHECK and each author writes it again. Rejected: a state that holds the columns of a kind; it ties a lifecycle to a value that is not one.
- Writing a new entity before deleting the old one makes a replaced value a duplicate for one statement. Rejected: `ON DELETE CASCADE`; it changes keys applications have migrated and hides the deletes from the statement count a spec reads. Rejected: deferrable unique indexes; a violation at commit would surface after the command's rescue, as a raw error.
- The graph is read, not mapped to commands, because one state can be entered by two commands. Rejected: `to ship(…), moves: :shipped`; it is another declared list beside the body.
- Removing by a timestamp keeps every reference valid. Rejected: deleting rows. Deferred: a partial unique index that frees a removed aggregate's values ([#274](https://github.com/caramelizedev/caramel/issues/274)); SugarORM does not declare one.
- Rejected: patterns as CHECK constraints. PostgreSQL reads regular expressions differently from Crystal.
- Rejected: a PostgreSQL enum for the state. `ALTER TYPE` cannot drop a value.
- SugarORM compares expression checks by name only, because PostgreSQL rewrites their text; hence the hash.
- A violation maps by the constraint's name because SugarORM's changeset maps by the leading column, which is not a sentence. SQL says nothing a reader can show, so `check` requires one.
- A value's refusal is shared by every attribute of its type.
