require "spec"
require "../../src/caramel/database"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
# Never accept DATABASE_URL: integration checks must not target application data.
url = ENV["CARAMEL_OWNED_SPEC_URL"]? || raise "Run scripts/check integration; no owned test database provided"

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
