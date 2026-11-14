# ADR 0052: SugarORM types PostgreSQL's conflicts, retries a transaction only when asked, and totals, joins and pages in one statement each

Date: 2026-10-31

Status: accepted.

## Context

#133 listed what SugarORM lacked for an application with real data. Four gaps decided how an application behaves under load: a foreign-key violation, a serialization failure and a deadlock surfaced as PostgreSQL's raw error; a transaction PostgreSQL rolled back for a conflict could not be run again without code written around it; a report needed a total, a join, another aggregate, or every row at once; and a `has_one` preload loaded every matching child. A generated Destroy answered 500 when other rows still referenced the record. The other gaps #133 named are issues of their own, listed in #282.

## Decision

The rules an application relies on are stated on the website ([site.html](../../website/source/site.html)), in its SugarORM reference, in the sections cited below by anchor, and in the doc comments under [src/sugar_orm](../../src/sugar_orm). This record states what was chosen. Schemas, changesets, preloads and keys, including the bounded `has_one` preload, are in [ADR 0007](0007-sugarorm.md).

1. **Every Repo statement raises a typed error for the codes an application answers.** SQLSTATE 23503 is `SugarORM::ForeignKeyViolation`, 23505 `UniqueViolation` and 23514 `CheckViolation`, each with `table` and `constraint`; 40001 is `SerializationFailure` and 40P01 `DeadlockDetected`, both `TransactionConflict`. Each keeps PostgreSQL's error as its `cause`, and any other code stays PostgreSQL's own error. The outermost transaction maps the error of its COMMIT the same way, so a serialization failure found at commit is typed too (`site#c-sugarorm-conflicts`).
2. **Retry is opt-in and outermost.** `Repo.transaction(retries: n)` runs the block again, on a fresh connection and transaction, when it raises a `TransactionConflict` that rolled it back, at most `n` more times and with no pause. `retries:` above 0 inside an open transaction is refused. `Repo.rollback` keeps its meaning. A block that runs again must be safe to run again; nothing outside the database is undone (`Repo.transaction`, `site#c-sugarorm-conflicts`).
3. **Aggregates return PostgreSQL's exact text.** `sum_text(:field)` and `group_sum_text(:by, :of)` return a sum, or one per value of `by` in its order, and the caller builds its own type. `min_text`, `max_text` and `avg_text` return a field's minimum, maximum or average the same way, and `group_count(:by)` counts the rows per value of `by`. Each is one statement over the query's conditions, the tenant's included. A limit or offset wraps a subquery, and a lock is refused. Return types, the nil and NULL cases and what `group_count` refuses are in `Query#sum_text`, `Query#group_sum_text`, `Query#group_count` and `site#c-sugarorm-reading`.
4. **`where_in` narrows by a parent query without a join.** `where_in(:field, parent)` keeps the rows whose field is a key `parent` matches, as `IN (SELECT …)` with the parent's conditions and tenant, read when it is called (`Query#where_in`).
5. **Joins go through `belongs_to` only.** `joins(:parent)` and `joins(:parent, query)` add an INNER JOIN with the rows `query` matches, its conditions and tenant read when `joins` is called, and `order_by_joined(:parent, :field, :asc)` orders by a column of that parent. A `has_many` or `has_one` has no `joins`. A parent query that has joins is refused, whether passed to `joins` or to `where_in`; the other refusals are in `site#c-sugarorm-reading`. Selecting or grouping by a joined column is not provided (#281).
6. **Batches and pages read by primary key.** `each_batch(size = 1000)` and `page(size, after: nil, direction: :asc)` set their own order and limit, so they refuse a query that has one. `page` returns `SugarORM::Page(R, K)`, whose cursor is the last row's key, of the schema's key type, `UUID` or `Int64`. What each yields, returns and refuses is in `Query#each_batch`, `Query#page` and `site#c-sugarorm-reading`. A cursor over another column is not provided (#279).
7. **A generated Destroy answers 409.** `Caramel::Action#conflict(message)` answers 409, and the Destroy that `frappe make resource` generates rescues `ForeignKeyViolation` with "<Model> is still in use", a locale key `in_use` when the application has locales.

## Reasons

- A foreign-key violation, a serialization failure and a deadlock are conditions an application handles, each in its own way: a 409, a retry. A raw `PQ::PQError` makes every caller match SQLSTATE strings. They are mapped as the unique and the check violation are.
- A retry that runs without being asked would repeat work the author never marked as safe, so `retries:` defaults to 0. It runs only outermost: PostgreSQL has rolled the whole transaction back, and a savepoint cannot rerun what the transaction around it did.
- Text keeps a PostgreSQL sum exact without a Crystal type per column pair: `sum(int)` is a `bigint`, `sum(bigint)` and `sum(numeric)` are `numeric`, and only the caller knows which value to build.
- `where_in` says the join without naming a table or a column, and carries the parent's own conditions and tenant, so rows the parent query excludes are excluded from the child's read too.
- The joined parent is a derived table whose columns are aliased `sugar_<name>__<column>`. The base query's `where`, `order_by` and aggregates write unqualified column names, so a second table with the same names would make every one ambiguous; the prefix keeps them unambiguous without rewriting them to be qualified.
- Keyset by primary key needs no encoding: the cursor is the last row's key, typed, an `Int64` or a UUIDv7, whose leading time keeps it in creation order, and a page costs one indexed range read where `offset` reads and discards every earlier row.
- **Rejected: retrying by default.** It would change what every existing transaction does on a conflict, and run side effects twice.
- **Rejected: sleeping between retries.** PostgreSQL already waited out the deadlock timeout, and a fixed pause is a guess; the caller who wants a backoff retries in a loop of their own.
- **Rejected: typed sums.** An overload per column type and per key type, when one text terminal and one conversion by the caller do the same.
- **Rejected: qualifying every column the query writes.** It touches each terminal and every raw fragment an application wrote, which cannot be qualified.
- **Rejected: an opaque cursor.** Encoding adds a format to version and tamper-proof; a primary key is a number the caller already holds.
