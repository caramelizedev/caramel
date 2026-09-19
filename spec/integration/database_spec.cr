require "spec"
require "../../src/caramel/database"
require "../../src/caramel/migration"

# Only scripts/integration supplies these URLs for its newly owned cluster.
# Never accept DATABASE_URL: integration checks must not target application data.
url = ENV["CARAMEL_OWNED_SPEC_URL"]? || raise "Run scripts/integration; no owned test database provided"

describe "PostgreSQL integration" do
  it "binds SQL-looking input and uses a distinct non-superuser spec database" do
    db = Caramel::Database.open(url)
    begin
      db.query_one("SELECT current_database()", as: String).should eq("caramel_spec")
      db.query_one("SELECT rolsuper FROM pg_roles WHERE rolname = current_user", as: Bool).should be_false
      db.query_one("SHOW timezone", as: String).should eq("UTC")
      value = "'); DROP TABLE books; --"
      db.query_one("SELECT $1::text", value, as: String).should eq(value)
      dev = Caramel::Database.open(ENV["CARAMEL_OWNED_DEV_URL"])
      begin
        dev.query_one("SELECT current_database()", as: String).should eq("caramel_development")
      ensure
        dev.close
      end
    ensure
      db.close
    end
  end

  it "applies explicit migrations once and rolls back a failed batch" do
    db = Caramel::Database.open(url)
    begin
      migration = Caramel::Migration.new(1_i64, "Create books", ["CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title text NOT NULL)"])
      runner = Caramel::Migrator.new(db, [migration])
      runner.pending.map(&.version).should eq([1_i64])
      db.query_one("SELECT to_regclass('caramel_migrations')::text", as: String?).should be_nil
      runner.migrate.should eq(1)
      runner.migrate.should eq(0)
      db.exec("INSERT INTO books (title) VALUES ($1)", "A book")
      db.query_one("SELECT title FROM books", as: String).should eq("A book")
      broken = Caramel::Migration.new(2_i64, "Broken", ["CREATE TABLE rollback_probe (id int)", "INSERT INTO absent_table VALUES (1)"])
      expect_raises(PQ::PQError) { Caramel::Migrator.new(db, [migration, broken]).migrate }
      db.query_one("SELECT to_regclass('rollback_probe')::text", as: String?).should be_nil
      runner.pending.should be_empty
      changed = Caramel::Migration.new(1_i64, "Create books", ["CREATE TABLE changed (id int)"])
      expect_raises(Caramel::Migrator::Drift) { Caramel::Migrator.new(db, [changed]).pending }
    ensure
      db.close
    end
  end

  it "verifies TLS trust and hostname rather than just encryption" do
    tls = Caramel::Database.open(ENV["CARAMEL_OWNED_TLS_URL"])
    begin
      tls.query_one("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", as: Bool).should be_true
    ensure
      tls.close
    end
    expect_raises(OpenSSL::SSL::Error, /certificate verify failed/) { Caramel::Database.open(ENV["CARAMEL_OWNED_WRONG_HOST_URL"]) }
    expect_raises(OpenSSL::SSL::Error, /certificate verify failed/) { Caramel::Database.open(ENV["CARAMEL_OWNED_UNTRUSTED_URL"]) }
  end
end
