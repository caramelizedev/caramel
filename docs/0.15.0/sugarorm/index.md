Reference / SugarORM

# Give your data shape.

Declare each table as a typed schema, query it with checked names, guard writes with changesets, and derive migrations from the declaration.

| Contract | Value |
| --- | --- |
| Release | 0.15.0 |
| Needs | A Caramel application and its development database |
| Covers | Schemas, codecs, queries, preloads, changesets, migrations, branches |
| Proved by | `frappe check` and `frappe migrate` |

Learning it for the first time? The recipe [Create a resource](https://caramelize.dev/cookbook/0.15.0/create-a-resource/index.md) generates a model, a changeset and a migration. This page lists every rule and limit.

## Limits at a glance {#c-sugarorm-limits}

| Limit | Value |
| --- | --- |
| `primary: true` fields per schema | 1 |
| Extra queries per `preload` | 1 |
| Starting value of a `version: true` column | 0 |
| Branch name after its first lowercase letter: lowercase letters, digits, underscores | up to 30 |

## A model declares its table once {#c-sugarorm-schemas}

A model is a struct that extends `SugarORM::Schema` and declares its table once. The schema block defines the record type, its queries and its migrations. `frappe make resource` writes one for you.

[Create a resource →](https://caramelize.dev/cookbook/0.15.0/create-a-resource/index.md)

**app/models/book.cr**

```crystal
module App
  struct Book < SugarORM::Schema
    schema "books" do
      field id : Int64, primary: true
      field title : String
      field isbn : String?, renamed_from: :code
      field copies : Int32 = 1
      field archived : Bool = false
      timestamps
      belongs_to author : Author
      index :isbn, unique: true
      check copies: 0..
      drop_column :shelf
    end

    scope available { where(archived: false) }
    scope with_copies(count : Int32) { where("copies >= ?", count) }
  end
end
```

Fields take `String`, `Int32`, `Int64`, `Bool`, `Float64` or `Time`, or any type through `codec:`; add `?` for a nullable column.

| Condition | Outcome |
| --- | --- |
| An unsupported field type | fails compilation |
| A default that is not a literal (it becomes the column’s SQL default), or any default on a `Time` field | fails compilation |
| A `primary: true` field that is nilable, not `Int64`, or has a default | fails compilation |
| The one `primary: true` field | is a non-nilable `Int64` without a default, stored as an identity column |
| `timestamps` | adds `created_at` and `updated_at` |
| An update that changes a field | also sets `updated_at` |
| A `has_many` or `has_one` whose foreign key the target lacks | fails compilation |
| A duplicate column | fails compilation |
| Two schemas that name one table | fails compilation |
| A reserved name such as `query` or `update` | fails compilation |
| A record | is immutable: `book.with(title: "Dune Messiah")` returns a changed copy and never persists it |

- `belongs_to author : Author`: Adds the author_id Int64 column, its foreign key and its index. Author? makes it nullable.
- `has_many books : Book`: Reads the Book rows whose author_id points at this record.
- `has_one charter : Charter`: Reads the first matching row by primary key, or nil.
- `index :isbn, unique: true`: Creates index_books_on_isbn. Several columns join with _and_ in the name.
- `check copies: 0..`: Adds the CHECK constraint check_books_copies. Range checks take Int32 and Int64 fields; 1..10 bounds both ends.
- `check :dates, "starts_at  ends_at"`: A named SQL expression, compared by name: rename it to change it.
- `renamed_from: :code`: Renames the old column instead of dropping it.
- `drop_column :shelf`: Records the decision to drop a column and its data.

`has_many` and `has_one` expect a foreign key named after the owner, such as `author_id`; pass `foreign_key: :column` when it differs.

## Codecs map other types to text {#c-sugarorm-codecs}

A field of any other type names a codec: `field name : Type, codec: Codec`. The codec maps the type to text. Rows read a codec column as text and writes bind the encoded text, so no value passes through a float.

| Codec method | Returns |
| --- | --- |
| `Codec.sql_type` | The column type, one of `numeric`, `numeric(P,S)`, `jsonb` or `text` |
| `Codec.encode(value)` | The text to store |
| `Codec.decode(text)` | Builds the value back |

`SugarORM::JSONB(T)` is a codec for any `JSON::Serializable` type, `JSON::Any`, or an Array or Hash of those. It stores the value in a `jsonb` column.

**app/models/invoice.cr**

```crystal
module App
  struct Snapshot
    include JSON::Serializable
    getter lines : Array(Hash(String, String))

    def initialize(@lines)
    end
  end

  struct Invoice < SugarORM::Schema
    schema "invoices" do
      field id : Int64, primary: true
      field snapshot : Snapshot, codec: SugarORM::JSONB(Snapshot)
      field notes : Snapshot?, codec: SugarORM::JSONB(Snapshot)
    end
  end
end
```

A numeric column keeps exact decimals. This codec holds the digits as text, so the application picks its own decimal type and checks the text in `decode`.

**app/models/rate.cr**

```crystal
module App
  record Rate, text : String

  module RateCodec
    def self.sql_type : String
      "numeric(20,8)"
    end

    def self.encode(rate : Rate) : String
      rate.text
    end

    def self.decode(text : String) : Rate
      raise ArgumentError.new("not a decimal: #{text}") unless text.matches?(/\A-?\d+(\.\d+)?\z/)
      Rate.new(text)
    end
  end

  struct Price < SugarORM::Schema
    schema "prices" do
      field id : Int64, primary: true
      field rate : Rate, codec: RateCodec
      field fee : Rate?, codec: RateCodec
    end
  end
end
```

| Condition | Outcome |
| --- | --- |
| A codec field with a default | fails compilation |
| A changeset `param` on a codec field | uses the field’s type, such as `Rate` |
| The number validators on a codec field | do not apply, because the stored value is text |
| `validate_inclusion` on a codec field | takes values of the field’s type |
| Raw SQL reading a codec column | selects it as text, as in `SELECT rate::text AS rate FROM prices` |
| `frappe db diff` on a codec field | derives the column from `sql_type` |
| Adding a required codec field to an existing table | halts the diff, because it has no default: add it nilable, backfill, then make it required |

In `where` a codec field takes a value or `nil`, never an Array or a Range. `BigDecimal` needs libgmp, which managed builds do not link, so keep decimals behind a codec of your own.

## Queries check names and types {#c-sugarorm-queries}

`Book.query` starts an immutable query, and each clause returns a new one. Keyword `where` accepts only the schema’s columns, with their types.

| where value | Matches |
| --- | --- |
| A value | Compares with `=` |
| An Array | Matches any element |
| A Range | Bounds a number or time column |
| The literal `nil` | Finds NULL in a nullable column, as `where_null(:isbn)` does |
| A string fragment | Binds one value to each `?`, in parentheses |
| `where_condition(SugarORM::Condition.new(sql, values))` | Adds a fragment built elsewhere with its values, in parentheses |

| Condition | Outcome |
| --- | --- |
| Keyword `where` with a name that is not a column, or a value of the wrong type | fails compilation |
| `where` with a value that may be nil, such as an optional contract field (it would match the NULL rows) | fails compilation; narrow it first (`if isbn = contract.isbn`) or use `where_null` |
| `order_by` with a name that is not a field, or a direction other than `:asc` or `:desc` | fails compilation |
| `find` and `first` when nothing matches | return nil |
| `find!` and `first!` when nothing matches | raise `SugarORM::NotFound` |

**Inside an action · author is a loaded App::Author**

```crystal
books = App::Book.query
  .available
  .with_copies(2)
  .where(author_id: author.id, copies: 1..10)
  .order_by(:title, :desc)
  .limit(20)
books.to_a
App::Book.query.find(id)
App::Book.query.where(isbn: nil).first!
```

| Call | Result |
| --- | --- |
| `order_by(:title, :desc)` | Orders by a field, `:asc` or `:desc` |
| `offset`, `first`, `count`, `exists?`, `each`, `delete_all` | Also available on a query |
| `scope name { … }` | Becomes a chainable query method |
| `to_sql` | Shows the statement |

`lock` adds `FOR UPDATE`.

| Condition | Outcome |
| --- | --- |
| `lock` | adds `FOR UPDATE`: the rows the query returns stay locked until the transaction ends, and a competing transaction waits for them |
| A locking query outside a transaction | raises, because the lock would end with the statement |
| `count`, `exists?` or `delete_all` on a locking query | refuses |
| A tenanted model with `lock` | keeps its tenant scope |
| Preloaded associations under `lock` | are not locked |

Lock several rows in one order, as in `order_by(:id).lock`, so two transactions cannot wait on each other. A lock does not replace a permission check.

**Inside an action**

```crystal
SugarORM::Repo.transaction do
  book = App::Book.query.lock.find!(id)
  book.update!(copies: book.copies - 1)
end
```

## Associations load only when preloaded {#c-sugarorm-preload}

An association stays unloaded until its query preloads it.

**Inside an action**

```crystal
authors = App::Author.query.preload(:books).order_by(:name).to_a
authors.each { |loaded| puts "#{loaded.name}: #{loaded.books.size}" }
```

| Condition | Outcome |
| --- | --- |
| A `preload` | adds one query that loads the association for every record in the result, so a list never runs one query per row |
| A preloaded result | wraps each record and still answers its fields |
| An association that was not preloaded | fails compilation, not a hidden query: `frappe check` reports `N_PLUS_ONE` (`Association 'books' of App::Author was not preloaded.`) and its remediation names `.preload(:books)` |

## SugarORM.sql reads rows as named tuples {#c-sugarorm-sql}

For CTEs, window functions and aggregates, `SugarORM.sql` runs a query with `$1` binds and reads each row as a named tuple.

**Inside an action**

```crystal
totals = SugarORM.sql(<<-SQL, as: {author_id: Int64, total: Int64})
  SELECT author_id, count(*) AS total FROM books GROUP BY author_id
  SQL
totals.each { |row| puts "#{row[:author_id]}: #{row[:total]}" }
SugarORM.sql_exec("UPDATE books SET archived = true WHERE copies < $1", 1)
```

| Condition | Outcome |
| --- | --- |
| Result columns that differ from the `as:` keys, in order | raises `SugarORM::ShapeError` |
| `SugarORM.sql_exec` | returns the number of rows affected |
| `SugarORM.sql` and `SugarORM.sql_exec` | use the current connection, including an open transaction |
| Raw SQL on a tenanted model | is not tenant-scoped; add the tenant predicate yourself, or use `App::Book.query.lock` to lock a scoped row |

## Every write goes through a changeset {#c-sugarorm-changesets}

A changeset lists the fields a write may set with `param`, and its rules in `validate(cs)`.

**app/changesets/book.cr**

```crystal
module App
  class Book::Changeset < SugarORM::Changeset(App::Book)
    param title : String
    param isbn : String?
    param copies : Int32
    param author_id : Int64

    def validate(cs)
      cs.validate_presence(:title)
      cs.validate_length(:title, max: 200)
      cs.validate_greater_than(:copies, 0)
      cs.validate_format(:isbn, /\A[0-9-]+\z/, message: "needs only digits and dashes")
      cs.unique_constraint(:isbn)
    end
  end

  alias Book::CreateChangeset = Book::Changeset
  alias Book::UpdateChangeset = Book::Changeset
end
```

Before your rules run, SugarORM checks NOT NULL columns.

| Condition | Outcome |
| --- | --- |
| A `param` that names no schema field, or has an incompatible type | fails compilation |
| The primary key or a timestamp as a `param` | fails compilation |
| An insert that omits a NOT NULL column without a default | adds the error `is required` |
| A write that sets a NOT NULL column to nil | adds the error `is required` |
| Validations | run when the changeset is built |
| Every validator except `validate_length` | takes `message:` to replace its default |
| The number, length, format, inclusion and URL validators | skip values that did not change and nil values |
| `cs.add_error(:title, "is checked out")` | adds your own error |

These are the validators and their default messages:

| Validator | Default message |
| --- | --- |
| `validate_required(:title, :isbn)` | is required. Checks the current value: nil or a blank string fails. |
| `validate_presence(:title)` | can't be blank. Checks a changed value only. |
| `validate_length(:title, min: 2, max: 200)` | should be at least 2 character(s), or should be at most 200 character(s). |
| `validate_greater_than(:copies, 0)` | must be greater than 0 |
| `validate_less_than(:copies, 100)` | must be less than 100 |
| `validate_format(:isbn, /\A[0-9-]+\z/)` | has invalid format |
| `validate_inclusion(:copies, in: [1, 2, 3])` | is invalid |
| `validate_url(:website)` | must be an absolute http or https URL. Caramel adds this validator. |
| `unique_constraint(:isbn)` | has already been taken. Maps a unique violation of the index that starts with isbn. |
| `check_constraint(:copies)` | must be at least 0, or must be at most N. Maps a violation of the field’s range check; an expression check takes on: :field and reads is invalid. |

`errors` maps each field name to its messages, and `"_base"` holds errors about the whole record.

Translated applications replace these messages through the catalogs’ `caramel.errors` section.

[Translate framework messages →](https://caramelize.dev/docs/0.15.0/internationalization/index.md)

## Saves return a changeset {#c-sugarorm-saving}

Each schema generates `create` and `update`. Their keywords are the changeset’s params.

**Inside an action · author is a loaded App::Author**

```crystal
changeset = App::Book.create(title: "Dune", author_id: author.id)
if changeset.saved?
  book = changeset.record
else
  errors = changeset.errors
end

book = App::Book.create!(title: "Emma", author_id: author.id)
book = book.update!(copies: 3)
book.delete

SugarORM::Repo.transaction do
  shelf = App::Book.create!(title: "Persuasion", author_id: author.id)
  shelf.update!(copies: 2)
end
```

| Condition | Outcome |
| --- | --- |
| `create` and `update` | use `CreateChangeset` and `UpdateChangeset` when the model defines them, as generated resources do; otherwise a default changeset that permits every field except the primary key and timestamps, and maps each unique index and range check |
| An unknown or mistyped keyword | fails compilation at the call |
| `create` and `update` | return the changeset: `saved?` says whether the write happened, `valid?` whether validation passed, and `record` holds the stored row |
| `create!` and `update!` | return the stored record or raise `SugarORM::Invalid` with the error messages |
| Updating a row that no longer exists | adds `Record no longer exists` under `_base` |
| `delete` on a row already gone | returns false |
| `SugarORM::Repo.transaction` | commits when its block returns and rolls back when it raises |
| A nested transaction | becomes a savepoint; `SugarORM::Repo.rollback` undoes the innermost block |
| A unique violation mapped by `unique_constraint` | leaves the transaction usable |

A changeset can say what to do when a row with the same key exists.

| Condition | Outcome |
| --- | --- |
| `upsert on: :tea_id, update: [:sold]` | makes the insert `INSERT … ON CONFLICT` on that unique index |
| An index the schema does not declare | fails compilation |
| A key or `update:` field that is not a param of the changeset | fails compilation |
| A tenanted schema | includes the tenant in the index |
| Defaults, validations and the tenant stamp | still apply |
| The `update:` fields the changeset writes | are set from the new row, along with `updated_at` and the version |
| No `update:` fields | leave the existing row as it is |
| `record` | is the stored row either way |
| Concurrent inserts of one key | leave one row |

**app/changesets/sale.cr**

```crystal
module App
  class Sale::Record < SugarORM::Changeset(App::Sale)
    param tea_id : Int64
    param sold : Int32
    upsert on: :tea_id, update: [:sold]
  end
end
```

A version field stops two people from overwriting each other.

| Condition | Outcome |
| --- | --- |
| `field lock_version : Int32, version: true` that is nilable, not Int32 or Int64, or has a default | fails compilation |
| The version column | starts at 0; `frappe db diff` adds it as `integer NOT NULL DEFAULT 0` |
| Every changeset update | checks the version it loaded and adds one |
| A row that changed since you loaded it | writes nothing and adds `Record changed since you loaded it` under `_base`; `stale?` is true |
| A changeset given `lock_version:` | checks that version instead, so a form carries the version it was rendered from |
| An insert that names a version | raises ArgumentError |
| A delete | does not check the version |
| A stale form at the update action | answers 409, re-rendering the form with the errors |
| An `If-Match` header that names another version | answers 412 |
| The show action | sends the version as `self.etag` |

**app/models/book.cr · schema excerpt**

```crystal
schema "books" do
  field id : Int64, primary: true
  field title : String
  field lock_version : Int32, version: true
  timestamps
end
```

**app/views/books/form.cr · beside the CSRF field**

```crystal
input type: "hidden", name: "_csrf", value: @csrf_token
input type: "hidden", name: "lock_version", value: @values["lock_version"]? || ""
```

The update action declares `field lock_version : Int32` in its contract.

**app/actions/books/update.cr**

```crystal
module App::Books
  struct Update < App::ApplicationAction
    contract do
      field id : Int64
      field title : String
      field lock_version : Int32
    end

    def handle(contract : Contract)
      book = App::Book.query.find(contract.id) || return not_found
      unless if_match?(book.lock_version)
        return render_errors({"_base" => [SugarORM::Wording.record_stale]}, 412)
      end
      changes = book.update(title: contract.title, lock_version: contract.lock_version)
      return render_errors(changes.errors, changes.stale? ? 409 : 422) unless changes.saved?
      changes.record
    end
  end
end
```

**app/actions/books/show.cr · inside handle**

```crystal
book = App::Book.query.find(contract.id) || return not_found
self.etag = book.lock_version
book
```

## Migrations derive from the schema {#c-sugarorm-migrations}

Change the schema first, then derive the SQL.

**Terminal · inside the application**

```bash
frappe db diff --name add_copies
```

**Expect:** Prints `Wrote PATH` for each migration file it derives under `db/migrations/`; if the declared schema already matches, nothing is written.

**Terminal · inside the application**

```bash
frappe migrate
```

**Expect:** Lints every pending migration, then prints `Applied N migrations.` and reports schema drift without changing anything; `The database matches the declared schema.` when there is none.

Review each file before you apply it. Adding `copies` with a default and a unique `isbn` index to an existing `books` table writes this migration:

**db/migrations/20261002120000_add_copies.cr**

```crystal
# Derived from the declared schema. Once applied, a migration is immutable: change the schema and run frappe db diff again.
App::MIGRATIONS << SugarORM::Migration.new(20261002120000_i64, "add_copies", [
  <<-SQL,
    ALTER TABLE "books" ADD COLUMN "copies" integer NOT NULL DEFAULT 1
    SQL
])
```

| Condition | Outcome |
| --- | --- |
| `frappe db diff` | clones the development database into a scratch branch, applies pending migrations there, compares with the declared schema, writes the difference to `db/migrations/`, migrates the branch with the new files and compares again, removing them if anything still differs; the scratch branch is always dropped |
| An index on an existing table | goes in a second file, `…_add_copies_concurrently.cr`, as `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS`; it builds without blocking writes and runs outside a transaction |
| A check on an existing table | splits in two: the transactional file adds it `NOT VALID`, which refuses new rows that break it, and the `_concurrently` file validates it |
| Existing rows that break the check | stop `frappe migrate`, which names the constraint; it stays `NOT VALID` until you fix or delete those rows and migrate again |
| A `check_…` constraint that no schema declares | is dropped |
| Every other CHECK | stays in place with a note |
| `frappe migrate` | lints every pending migration before it runs any statement, applies them, then reports schema drift without changing anything |
| An applied migration that changed | stops the next run |

`frappe make resource` renders its `create_` migration the same way a diff would. The linter checks these rules:

| Lint rule | What it refuses |
| --- | --- |
| `concurrent-index` | CREATE INDEX on an existing table blocks its writes. Use CONCURRENTLY in a migration of its own. |
| `not-null-default` | ADD COLUMN … NOT NULL without a DEFAULT fails on a populated table. |
| `destructive-column` | DROP or RENAME COLUMN needs drop_column or renamed_from. Hand-written SQL needs a -- caramel:allow-drop or allow-rename table.column line. |
| `mixed-concurrency` | CONCURRENTLY statements cannot share a migration with statements that need a transaction. |

Tables created in the same migration are exempt from the first two rules.

| Condition | Outcome |
| --- | --- |
| A NOT NULL column without a default on an existing table | halts the diff and prints its remediation |
| A column that no field declares | halts the diff |
| A type change | halts the diff |
| A new NOT NULL constraint | halts the diff |
| A primary key change | is never derived |
| `frappe db diff --dev-override` | derives those changes anyway |
| `frappe migrate --dev-override` | turns lint violations into warnings |
| `frappe migrate --dev-override` outside `CARAMEL_ENV=development` | refuses (test and production always refuse) |

## A branch is a full copy of the database {#c-sugarorm-branches}

A database branch is a full copy of the development database. Use one to try a migration or a data change without touching your development records.

**Terminal · inside the application**

```bash
frappe db branch create try_isbn
```

**Expect:** Prints the branch’s connection URL.

**Terminal · inside the application**

```bash
frappe dev --branch try_isbn
```

**Expect:** Serves the application against the branch; a branch that does not exist is refused.

**Terminal · inside the application**

```bash
frappe db branch list
frappe db branch delete try_isbn
```

| Condition | Outcome |
| --- | --- |
| A branch name that does not start with a lowercase letter, or is followed by more than 30 lowercase letters, digits or underscores | refuses |
| While the copy is made | Latte closes other connections to the development database |
| `frappe dev --branch` with a branch that does not exist | refuses |

Branches are for experiments. To keep a backup, use `frappe db dump` and `frappe db restore`.

[Back up the development database →](https://caramelize.dev/docs/0.15.0/local-environment/index.md)

Prove it

## Check the schema against the database {#c-sugarorm-test}

**Terminal · inside the application**

```bash
frappe check
frappe migrate
```

**Passing:** `frappe check` reports no compile error and no `N_PLUS_ONE`, and `frappe migrate` ends with `The database matches the declared schema.`

[← Views](https://caramelize.dev/docs/0.15.0/views/index.md) · [Move work to the background →](https://caramelize.dev/docs/0.15.0/cold-brew/index.md)

Caramel 0.15.0 · https://caramelize.dev/docs/0.15.0/sugarorm/
