# ADR 0052: SugarORM conflicts, retries and reads at scale

Date: 2026-11-07

Status: accepted. Amends [ADR 0007](0007-sugarorm-schemas-changesets-preload.md) decisions
2, 4, 5 and 6.

## Context

#133 listed what SugarORM lacked for an application with real data. Four gaps decided how
an application behaves under load: a foreign-key violation, a serialization failure and a
deadlock surfaced as PostgreSQL's raw error; a transaction PostgreSQL rolled back for a
conflict could not be run again without code written around it; a report needed a join,
an aggregate other than a sum, or every row at once; and a `has_one` preload loaded every
matching child. A generated Destroy answered 500 when other rows still referenced the
record. The other gaps #133 named are issues of their own, listed in #282.

## Decision

1. **Errors.** Every Repo statement maps SQLSTATE 23503 to `SugarORM::ForeignKeyViolation`,
   with `table` and `constraint` as `UniqueViolation` and `CheckViolation` have, 40001 to
   `SerializationFailure` and 40P01 to `DeadlockDetected`. The last two are
   `TransactionConflict`. Each keeps PostgreSQL's error as its `cause`. Any other code stays
   PostgreSQL's own error. The outermost transaction maps the error of its COMMIT the same
   way, so a serialization failure found at commit is typed too.
2. **Retry is opt-in.** `Repo.transaction(retries: n)` runs the block again, on a fresh
   connection and transaction, when it raises a `TransactionConflict` that rolled it back,
   at most `n` more times and with no pause. It raises the last conflict. A negative `n`,
   and `retries:` above 0 inside an open transaction, raise `ArgumentError`: a savepoint
   cannot retry what its transaction already did. `Repo.rollback` keeps its meaning. A block
   that runs again must be safe to run again; nothing outside the database is undone.
3. **A `has_one` is bounded.** A preload reads one row per owner, the one with the lowest
   primary key, with `SELECT DISTINCT ON (fk) … ORDER BY fk, pk`. A `has_many` is not
   bounded.
4. **Aggregates.** `min_text`, `max_text` and `avg_text` return PostgreSQL's text, nil when
   no row matches or every value is NULL, and `group_count(:by)` returns
   `Array({String?, Int64})` ordered by the key, NULL last. They follow ADR 0049's `sum_text`
   and `group_sum_text`: a limit or offset wraps a subquery, a lock is refused, and
   `group_count` refuses `order_by`, limit and offset.
5. **Joins through `belongs_to`.** `joins(:parent)` and `joins(:parent, query)` add an INNER
   JOIN with the rows `query` matches (every row by default), its conditions and tenant read
   when `joins` is called. `order_by_joined(:parent, :field, :asc)` orders by a column of
   that parent. A has_many or has_one has no `joins`. The query refuses, with
   `ArgumentError`, a second `joins` of one association, `order_by_joined` before its
   `joins`, `lock` and `delete_all` with joins, and a parent query that has joins, whether
   passed to `joins` or to `where_in`. Selecting or grouping by a joined column is #281.
6. **Batches and pages by primary key.** `each_batch(size = 1000)` yields `Array`s of what
   `to_a` returns, one statement per batch, and stops after a short batch.
   `page(size, after: nil, direction: :asc)` returns `SugarORM::Page(R)` with `records` and
   `after`, the cursor for the next page, nil on the last. Both set their own order and
   limit, so they refuse a query with `order_by`, limit or offset, and a size below 1;
   `each_batch` refuses `lock`, and `page` a direction other than `:asc` and `:desc`. A
   cursor over another column is #279.
7. **A generated Destroy answers 409.** `Caramel::Action#conflict(message)` answers 409,
   and the Destroy `frappe make resource` generates rescues `ForeignKeyViolation` with
   "<Model> is still in use", a locale key `in_use` when the app has locales.

## Reasons

- A foreign-key violation, a serialization failure and a deadlock are conditions an
  application handles, each in its own way: a 409, a retry. A raw `PQ::PQError` made every
  caller match SQLSTATE strings. Mapping them follows the two codes already mapped.
- A retry that runs without being asked would repeat work the author never marked as safe,
  so `retries:` defaults to 0. It runs only outermost: PostgreSQL has rolled the whole
  transaction back, and a savepoint cannot rerun what the transaction around it did.
- The joined parent is a derived table whose columns are aliased `sugar_<name>__<column>`.
  The base query's `where`, `order_by` and aggregates write unqualified column names, so a
  second table with the same names would make every one ambiguous; the prefix keeps them
  unambiguous without rewriting them to be qualified.
- Keyset by primary key needs no encoding: the cursor is the last row's `Int64` key, typed,
  and a page costs one indexed range read where `offset` reads and discards every earlier
  row.
- `DISTINCT ON` returns the one row per owner in the statement itself; a has_one that loaded
  every child held them all in memory to keep one.

Rejected:

- **Retrying by default.** It would change what every existing transaction does on a
  conflict, and run side effects twice.
- **Sleeping between retries.** PostgreSQL already waited out the deadlock timeout, and a
  fixed pause is a guess; the caller who wants a backoff retries in a loop of their own.
- **Qualifying every column the query writes.** It touches each terminal and every raw
  fragment an application wrote, which cannot be qualified.
- **An opaque cursor.** Encoding adds a format to version and tamper-proof; a primary key is
  a number the caller already holds.
