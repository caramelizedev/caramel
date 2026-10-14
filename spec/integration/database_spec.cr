require "spec"
require "../../src/caramel/database"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
# Never accept DATABASE_URL: integration checks must not target application data.
missing = "Run scripts/check integration; no owned test database provided"
url = ENV["CARAMEL_OWNED_SPEC_URL"]? || raise missing

describe "PostgreSQL integration" do
  it "binds SQL-looking input and uses a distinct non-superuser spec database" do
    db = Caramel::Database.open(url)
    begin
      db.query_one("SELECT current_database()", as: String).should eq("caramel_spec")
      superuser = "SELECT rolsuper FROM pg_roles WHERE rolname = current_user"
      db.query_one(superuser, as: Bool).should be_false
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

  it "verifies TLS trust and hostname rather than just encryption" do
    tls = Caramel::Database.open(ENV["CARAMEL_OWNED_TLS_URL"])
    begin
      encrypted = "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
      tls.query_one(encrypted, as: Bool).should be_true
    ensure
      tls.close
    end
    %w[CARAMEL_OWNED_WRONG_HOST_URL CARAMEL_OWNED_UNTRUSTED_URL].each do |name|
      expect_raises(OpenSSL::SSL::Error, /certificate verify failed/) do
        Caramel::Database.open(ENV[name])
      end
    end
  end

  it "lets PostgreSQL end a statement at its statement timeout and keeps the connection" do
    limits = Caramel::Database::Limits.new(statement_timeout: 1.second, lock_timeout: 1.second)
    db = Caramel::Database.open(url, 1, limits: limits)
    begin
      db.query_one("SHOW statement_timeout", as: String).should eq("1s")
      pid = db.query_one("SELECT pg_backend_pid()", as: Int32)
      expect_raises(PQ::PQError, /statement timeout/) do
        db.exec("SELECT pg_sleep(3)")
      end
      db.query_one("SELECT pg_backend_pid()", as: Int32).should eq(pid)
    ensure
      db.close
    end
  end

  it "waits past IO_TIMEOUT when there is no statement timeout" do
    limits = Caramel::Database::Limits.new(Time::Span.zero, Time::Span.zero)
    db = Caramel::Database.open(url, 1, limits: limits)
    begin
      db.exec("SELECT pg_sleep(6)")
    ensure
      db.close
    end
  end

  it "ends a lock wait at the lock timeout" do
    holder = Caramel::Database.open(url, 1)
    waiter_limits = Caramel::Database::Limits.new(statement_timeout: 10.seconds,
      lock_timeout: 1.second)
    waiter = Caramel::Database.open(url, 1, limits: waiter_limits)
    begin
      holder.using_connection do |connection|
        connection.exec("SELECT pg_advisory_lock(8118)")
        begin
          expect_raises(PQ::PQError, /lock timeout/) do
            waiter.exec("SELECT pg_advisory_lock(8118)")
          end
        ensure
          connection.exec("SELECT pg_advisory_unlock(8118)")
        end
      end
    ensure
      waiter.close
      holder.close
    end
  end
end
