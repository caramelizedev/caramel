require "spec"
require "../../../src/caramel"

private def traced(action : String) : Caramel::Crema::Trace
  kind = Caramel::Crema::Kind::Request
  trace = Caramel::Crema::Trace.new(kind, "GET /books/:id", "a" * 32, "b" * 16)
  trace.sql_comment = Caramel::Crema.sql_tag("action", action)
  trace
end

private def tagged(trace : Caramel::Crema::Trace, sql : String) : String
  Caramel::Crema::Sql.observe(trace, sql, [] of SugarORM::Value) { |statement| statement }
end

describe "Crema statement tags" do
  it "prepends the encoded action to the statement" do
    sql = tagged(traced("App::Books::Show"), "SELECT 1")
    sql.should eq("/*action='App%3A%3ABooks%3A%3AShow'*/ SELECT 1")
  end

  it "keeps a trailing comment or semicolon from swallowing the tag" do
    sql = tagged(traced("App::Books::Show"), "SELECT 1; -- done")
    sql.should start_with("/*action='")
    sql.should end_with("SELECT 1; -- done")
  end

  it "cannot be closed early by a schedule name" do
    tag = Caramel::Crema.sql_tag("schedule", "nightly */ DROP TABLE x; /*")
    tag.scan("*/").size.should eq(1)
  end

  it "counts a statement as a database step of the bound trace" do
    trace = traced("App::Books::Show")
    Caramel::Crema.bound(trace) { tagged(trace, "SELECT 1") }
    trace.db_count.should eq(1)
  end

  it "summarizes a statement as its verb and first table" do
    select_books = %(SELECT "books".* FROM "books" WHERE id = $1)
    Caramel::Crema.summary(select_books).should eq("SELECT books")
    Caramel::Crema.summary("UPDATE authors SET name = $1").should eq("UPDATE authors")
    Caramel::Crema.summary("select pg_sleep(1)").should eq("SELECT")
  end
end
