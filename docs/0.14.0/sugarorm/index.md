Reference / SugarORM

# Give your data shape.

Declare each table as a typed schema, query it with checked names, guard writes with changesets, and derive migrations from the declaration.

## Declare the schema {#c-sugarorm-schemas}

A model is a struct that extends `SugarORM::Schema` and declares its table once. The schema block defines the record type, its queries and its migrations. `frappe make resource` writes one for you.

[Create a resource →](https://caramelize.dev/cookbook/0.14.0/create-a-resource/index.md)

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

Fields take `String`, `Int32`, `Int64`, `Bool`, `Float64` or `Time`, or any type through `codec:`; add `?` for a nullable column. A default must be a literal, because it becomes the column’s SQL default; `Time` fields take none. The one `primary: true` field is a non-nilable `Int64` without a default, stored as an identity column. `timestamps` adds `created_at` and `updated_at`; an update that changes a field also sets `updated_at`.

- `belongs_to author : Author`: Adds the author_id Int64 column, its foreign key and its index. Author? makes it nullable.
- `has_many books : Book`: Reads the Book rows whose author_id points at this record.
- `has_one charter : Charter`: Reads the first matching row by primary key, or nil.
- `index :isbn, unique: true`: Creates index_books_on_isbn. Several columns join with _and_ in the name.
- `check copies: 0..`: Adds the CHECK constraint check_books_copies. Range checks take Int32 and Int64 fields; 1..10 bounds both ends.
- `check :dates, "starts_at  ends_at"`: A named SQL expression, compared by name: rename it to change it.
- `renamed_from: :code`: Renames the old column instead of dropping it.
- `drop_column :shelf`: Records the decision to drop a column and its data.

`has_many` and `has_one` expect a foreign key named after the owner, such as `author_id`; pass `foreign_key: :column` when it differs. Unsupported types, non-literal defaults, missing foreign keys, duplicate columns, two schemas that name one table and reserved names such as `query` or `update` fail compilation at the declaration.

Records are immutable. `book.with(title: "Dune Messiah")` returns a changed copy and never persists it.

## Store other types through a codec {#c-sugarorm-codecs}

A field of any other type names a codec: `field name : Type, codec: Codec`. The codec maps the type to text. `Codec.sql_type` is the column type, one of `numeric`, `numeric(P,S)`, `jsonb` or `text`. `Codec.encode(value)` returns the text to store, and `Codec.decode(text)` builds the value back. Rows read a codec column as text and writes bind the encoded text, so no value passes through a float.

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

A codec field takes no default; set it in a changeset. In `where` it takes a value or `nil`, never an Array or a Range. A changeset `param` uses the field’s type, such as `Rate`, and the number validators do not apply because the stored value is text; `validate_inclusion` takes values of the field’s type. In raw SQL, select the column as text, as in `SELECT rate::text AS rate FROM prices`. `frappe db diff` derives the column from `sql_type`. Adding a required codec field to an existing table halts, because it has no default: add it nilable, backfill, then make it required. `BigDecimal` needs libgmp, which managed builds do not link, so keep decimals behind a codec of your own.

## Query with checked names {#c-sugarorm-queries}

`Book.query` starts an immutable query, and each clause returns a new one. Keyword `where` accepts only the schema’s columns, with their types. A value compares with `=`, an Array matches any element, a Range bounds a number or time column, and the literal `nil` finds NULL in a nullable column, as `where_null(:isbn)` does. A value that may be nil, such as an optional contract field, does not compile, because it would match the NULL rows whenever it was nil: narrow it first (`if isbn = contract.isbn`) or use `where_null`. A string fragment binds one value to each `?`, and `where_condition(SugarORM::Condition.new(sql, values))` adds a fragment built elsewhere with its values; both go in parentheses.

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

`order_by` takes a field and `:asc` or `:desc`. Queries also have `offset`, `first`, `count`, `exists?`, `each` and `delete_all`. `find` and `first` return nil when nothing matches; `find!` and `first!` raise `SugarORM::NotFound`. A `scope` becomes a chainable query method. `to_sql` shows the statement.

`lock` adds `FOR UPDATE`: the rows the query returns stay locked until the transaction ends, and a competing transaction waits for them. A tenanted model keeps its tenant scope. A locking query outside a transaction raises, because the lock would end with the statement, and `count`, `exists?` and `delete_all` refuse it. Lock several rows in one order, as in `order_by(:id).lock`, so two transactions cannot wait on each other. Preloaded associations are not locked, and a lock does not replace a permission check.

**Inside an action**

```crystal
SugarORM::Repo.transaction do
  book = App::Book.query.lock.find!(id)
  book.update!(copies: book.copies - 1)
end
```

## Preload associations {#c-sugarorm-preload}

An association stays unloaded until its query preloads it. Each `preload` adds one query that loads the association for every record in the result, so a list never runs one query per row.

**Inside an action**

```crystal
authors = App::Author.query.preload(:books).order_by(:name).to_a
authors.each { |loaded| puts "#{loaded.name}: #{loaded.books.size}" }
```

A preloaded result wraps each record and still answers its fields. Using an association that was not preloaded is a compile error, not a hidden query. `frappe check` reports it as `N_PLUS_ONE`: `Association 'books' of App::Author was not preloaded.` Its remediation names `.preload(:books)`.

## Write SQL by hand {#c-sugarorm-sql}

For CTEs, window functions and aggregates, `SugarORM.sql` runs a query with `$1` binds and reads each row as a named tuple. The result columns must equal the `as:` keys in order, or it raises `SugarORM::ShapeError`. `SugarORM.sql_exec` runs a statement and returns the number of rows affected. Both use the current connection, including an open transaction.

**Inside an action**

```crystal
totals = SugarORM.sql(<<-SQL, as: {author_id: Int64, total: Int64})
  SELECT author_id, count(*) AS total FROM books GROUP BY author_id
  SQL
totals.each { |row| puts "#{row[:author_id]}: #{row[:total]}" }
SugarORM.sql_exec("UPDATE books SET archived = true WHERE copies < $1", 1)
```

Raw SQL is not tenant-scoped, so add the tenant predicate yourself, or use `App::Book.query.lock` to lock a scoped row.

## Check every write with a changeset {#c-sugarorm-changesets}

A changeset lists the fields a write may set with `param`, and its rules in `validate(cs)`. Each param must name a field of the schema with a compatible type. The primary key and timestamps cannot be params. Validations run when the changeset is built.

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

Before your rules run, SugarORM checks NOT NULL columns. An insert must supply every one that has no default, and no write may set one to nil. Each miss reads `is required`. These are the validators and their default messages:

- `validate_required(:title, :isbn)`: is required. Checks the current value: nil or a blank string fails.
- `validate_presence(:title)`: can't be blank. Checks a changed value only.
- `validate_length(:title, min: 2, max: 200)`: should be at least 2 character(s), or should be at most 200 character(s).
- `validate_greater_than(:copies, 0)`: must be greater than 0
- `validate_less_than(:copies, 100)`: must be less than 100
- `validate_format(:isbn, /\A[0-9-]+\z/)`: has invalid format
- `validate_inclusion(:copies, in: [1, 2, 3])`: is invalid
- `validate_url(:website)`: must be an absolute http or https URL. Caramel adds this validator.
- `unique_constraint(:isbn)`: has already been taken. Maps a unique violation of the index that starts with isbn.
- `check_constraint(:copies)`: must be at least 0, or must be at most N. Maps a violation of the field’s range check; an expression check takes on: :field and reads is invalid.

Every validator except `validate_length` takes `message:` to replace its default. The number, length, format, inclusion and URL validators skip values that did not change and nil values. `cs.add_error(:title, "is checked out")` adds your own error. `errors` maps each field name to its messages, and `"_base"` holds errors about the whole record.

Translated applications replace these messages through the catalogs’ `caramel.errors` section.

[Translate framework messages →](https://caramelize.dev/docs/0.14.0/internationalization/index.md)

## Save through the model {#c-sugarorm-saving}

Each schema generates `create` and `update`. They use `CreateChangeset` and `UpdateChangeset` when the model defines them, as generated resources do. Otherwise they use a default changeset that permits every field except the primary key and timestamps, and maps each unique index and range check. Their keywords are the changeset’s params, so an unknown or mistyped keyword fails at the call.

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

`create` and `update` return the changeset. `saved?` says whether the write happened, `valid?` whether validation passed, and `record` holds the stored row. `create!` and `update!` return the stored record or raise `SugarORM::Invalid` with the error messages. Updating a row that no longer exists adds `Record no longer exists` under `_base`. `delete` returns false when the row was already gone.

`SugarORM::Repo.transaction` commits when its block returns and rolls back when it raises. A nested transaction becomes a savepoint, and `SugarORM::Repo.rollback` undoes the innermost block. A unique violation mapped by `unique_constraint` leaves the transaction usable.

A changeset can say what to do when a row with the same key exists. `upsert on: :tea_id, update: [:sold]` makes its insert `INSERT … ON CONFLICT` on that unique index. The index must be one the schema declares, or the program does not compile; on a tenanted schema it includes the tenant. Defaults, validations and the tenant stamp still apply. The `update:` fields the changeset writes are set from the new row, along with `updated_at` and the version. With none, the existing row stays as it is. Either way `record` is the stored row, and concurrent inserts of one key leave one row. The key and `update:` fields must be params of the changeset.

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

A version field stops two people from overwriting each other. `field lock_version : Int32, version: true` takes an Int32 or Int64 with no default; the column starts at 0, and `frappe db diff` adds it as `integer NOT NULL DEFAULT 0`. Every changeset update checks the version it loaded and adds one. When the row changed, nothing is written: the changeset adds `Record changed since you loaded it` under `_base`, and `stale?` is true. A changeset given `lock_version:` checks that version instead, so a form carries the version it was rendered from. Deletes do not check it, and an insert cannot name one.

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

The update action declares `field lock_version : Int32` in its contract and answers a stale form with 409, re-rendering the form with the errors. It answers 412 when an `If-Match` header names another version. The show action sends the version as `self.etag`.

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

## Derive migrations {#c-sugarorm-migrations}

Change the schema first, then derive the SQL. `frappe db diff` clones the development database into a scratch branch and applies pending migrations there. It compares the result with the declared schema and writes the difference to `db/migrations/`. It then migrates the branch with the new files and compares again; if anything still differs, it removes them. The scratch branch is always dropped.

**Terminal · inside the application**

```bash
frappe db diff --name add_copies
frappe migrate
```

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

The index goes in a second file, `…_add_copies_concurrently.cr`, as `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS`. It builds without blocking writes, so it runs outside a transaction.

A check added to an existing table is also split in two. The transactional file adds it `NOT VALID`, so it refuses new rows that break it, and the `_concurrently` file validates it. If existing rows break the check, `frappe migrate` stops and names the constraint; it stays `NOT VALID` until you fix or delete those rows and migrate again. SugarORM owns the checks named `check_…`: it drops one that no schema declares, and leaves every other CHECK in place with a note.

`frappe migrate` lints every pending migration before it runs any statement, applies them, then reports schema drift without changing anything. An applied migration must not change; a changed one stops the next run. `frappe make resource` renders its `create_` migration the same way a diff would.

- `concurrent-index`: CREATE INDEX on an existing table blocks its writes. Use CONCURRENTLY in a migration of its own.
- `not-null-default`: ADD COLUMN … NOT NULL without a DEFAULT fails on a populated table.
- `destructive-column`: DROP or RENAME COLUMN needs drop_column or renamed_from. Hand-written SQL needs a -- caramel:allow-drop or allow-rename table.column line.
- `mixed-concurrency`: CONCURRENTLY statements cannot share a migration with statements that need a transaction.

Tables created in the same migration are exempt from the first two rules. The diff also halts instead of writing risky SQL: a NOT NULL column without a default on an existing table, a column that no field declares, a type change or a new NOT NULL constraint. Each halt prints its remediation. Primary key changes are never derived.

In development, `frappe db diff --dev-override` derives those changes anyway, and `frappe migrate --dev-override` turns lint violations into warnings. The migrate override applies only when `CARAMEL_ENV=development`; test and production always refuse.

## Try changes on a branch {#c-sugarorm-branches}

A database branch is a full copy of the development database. Use one to try a migration or a data change without touching your development records.

**Terminal · inside the application**

```bash
frappe db branch create try_isbn
frappe dev --branch try_isbn
frappe db branch list
frappe db branch delete try_isbn
```

`create` prints the branch’s connection URL. A branch name starts with a lowercase letter, followed by up to 30 lowercase letters, digits or underscores. While the copy is made, Latte closes other connections to the development database. `frappe dev --branch` serves the application against the branch and refuses a branch that does not exist.

Branches are for experiments. To keep a backup, use `frappe db dump` and `frappe db restore`.

[Back up the development database →](https://caramelize.dev/docs/0.14.0/local-environment/index.md)

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Move work to the background →](https://caramelize.dev/docs/0.14.0/cold-brew/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/sugarorm/
