require "spec"
require "../../src/caramel/database"
require "../../src/sugar_orm"
require "../../src/caramel/crema/sql_copy"

# Only scripts/check integration supplies this URL for its newly owned cluster.
owner_url = ENV["CARAMEL_OWNED_SPEC_URL"]? ||
            raise "Run scripts/check integration; no owned test database provided"

alias Arguments = Array(SugarORM::Value)

# Rows of *sql* as JSON text, in the order the statement gives.
private def rows(connection : DB::Connection, sql : String, args : Arguments) : Array(String)
  wrapped = "SELECT to_jsonb(found)::text FROM (#{sql}) found"
  connection.query_all(wrapped, args: args, &.read(String))
end

describe "a statement copied with its values" do
  it "returns the rows the parameterised statement returns" do
    db = Caramel::Database.open(owner_url)
    begin
      db.using_connection do |connection|
        connection.exec(<<-SQL)
          CREATE TEMP TABLE copy_books (
            id integer PRIMARY KEY, n integer, price numeric, flag boolean,
            at timestamptz, name text, note text)
          SQL
        connection.exec(<<-SQL)
          INSERT INTO copy_books VALUES
            (1, 1, 1.5, true, '2026-10-01T00:00:00Z', 'plain', NULL),
            (2, 2, 2.25, false, '2026-10-05T12:30:00Z', 'it''s a  test', 'note'),
            (3, 3, 3, true, '2026-10-07T09:00:00Z', '2', 'a "quoted" $1 note'),
            (4, 4, 4.5, false, '2026-10-09T00:00:00Z', 'NULL', '')
          SQL

        order = "ORDER BY id"
        cases = [
          {"SELECT * FROM copy_books WHERE n = $1 #{order}", [2] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE n > $1 #{order} LIMIT $2 OFFSET $3",
           [1, 2, 1] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE flag = $1 #{order}", [true] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE at >= $1 #{order}",
           [Time.utc(2026, 10, 5, 12, 30, 0)] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE id = ANY($1) #{order}",
           [[1, 3]] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE name = ANY($1) #{order}",
           [["plain", "NULL"]] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE id IN ($1, $2) #{order}", [2, 4] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE name = $1 #{order}",
           ["it's a \\ test"] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE name = $1 #{order}", ["2"] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE name = $1 #{order}", ["NULL"] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE n = $1::int #{order}", [3] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE price = $1 #{order}", [2.25] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE note IS NOT DISTINCT FROM $1 #{order}",
           [nil] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE (name = E'it\\'s a \\\\ test' OR n = $1) " \
           "AND E'a $1' = 'a $1' #{order}",
           [4] of SugarORM::Value},
          {"SELECT id AS id$1 FROM copy_books WHERE n = $1 ORDER BY \"id$1\"",
           [2] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE name <> '\\' AND n = $1 #{order}",
           [1] of SugarORM::Value},
          {"SELECT * FROM copy_books WHERE note LIKE $1 AND n = $2 #{order}",
           ["%$1%", 3] of SugarORM::Value},
          {"SELECT $1::text AS a, $2::boolean AS b, $3::numeric AS c",
           ["x", false, 1.25] of SugarORM::Value},
        ]
        cases.each do |sql, args|
          literals = args.map { |arg| Caramel::Crema::Literal.of(arg) }
          copied = Caramel::Crema::SqlCopy.fill(sql, literals)
          expected = rows(connection, sql, args)
          rows(connection, copied, [] of SugarORM::Value).should eq(expected), copied
        end
      end
    ensure
      db.close
    end
  end
end
