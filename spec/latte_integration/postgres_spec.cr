require "spec"
require "file_utils"
require "json"
require "random/secure"
require "socket"
require "../../src/caramel/database"
require "../../src/latte/postgres"

root = ENV["CARAMEL_LATTE_ROOT"]? || raise "CARAMEL_LATTE_ROOT is required; run scripts/check-latte-postgres"
project = ENV["CARAMEL_LATTE_PROJECT"]? || raise "CARAMEL_LATTE_PROJECT is required"
paths = Caramel::Latte::Paths.new(root)
toolchain = Caramel::Latte::Toolchain.new
service = Caramel::Latte::Postgres.new(paths, toolchain)
site = Caramel::Latte::Site.new("bookshelf", project)
credentials = service.provision(site)

private def open_database(url : String, pool_size = 2) : DB::Database
  Caramel::Database.open(url, pool_size)
end

private def admin_password(service : Caramel::Latte::Postgres) : String
  JSON.parse(File.read(service.admin_secret_path))["password"].as_s
end

private def admin_query(
  sql : String,
  service : Caramel::Latte::Postgres,
  paths : Caramel::Latte::Paths,
  toolchain : Caramel::Latte::Toolchain,
  root : String,
) : String
  passfile = File.join(root, "admin-query-#{Random::Secure.hex(8)}.pgpass")
  File.write(passfile, "*:*:*:#{Caramel::Latte::Postgres::ADMIN_USER}:#{admin_password(service)}\n")
  File.chmod(passfile, 0o600)
  begin
    result = Caramel::Latte::ProcessRunner.run(
      [toolchain.psql, "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-h", paths.postgres_socket_dir,
       "-U", Caramel::Latte::Postgres::ADMIN_USER, "-d", "postgres"],
      input: sql,
      env: toolchain.environment({"PGPASSFILE" => passfile}),
      timeout: 10.seconds,
      output_limit: 16 * 1024,
    )
    result.success?.should be_true
    result.stdout
  ensure
    File.delete(passfile) if File.exists?(passfile)
  end
end

private def expect_database_failure(url : String, sql : String) : Nil
  db : DB::Database? = nil
  failed = false
  begin
    db = open_database(url, 1)
    db.not_nil!.exec(sql)
  rescue PQ::PQError | DB::Error
    failed = true
  ensure
    db.try(&.close)
  end
  failed.should be_true
end

describe "Latte managed PostgreSQL" do
  it "uses PostgreSQL 18, UTF8/UTC, no TCP listener, and a fixed connection cap" do
    service.running?.should be_true
    service.ready?.should be_true
    db = open_database(credentials.development_migration, 1)
    begin
      db.query_one("SELECT current_setting('server_version') LIKE '18.6%'", as: Bool).should be_true
      db.query_one("SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = current_database()", as: String).should eq("UTF8")
      db.query_one("SHOW timezone", as: String).should eq("UTC")
      db.query_one("SELECT current_setting('listen_addresses')", as: String).should eq("")
      admin_query("SELECT current_setting('unix_socket_directories');", service, paths, toolchain, root).strip.should eq(paths.postgres_socket_dir)
      admin_query("SELECT current_setting('unix_socket_permissions');", service, paths, toolchain, root).strip.should eq("0700")
      db.query_one("SELECT current_setting('max_connections')", as: String).should eq("64")
      admin_query("SELECT current_setting('password_encryption');", service, paths, toolchain, root).strip.should eq("scram-sha-256")
      admin_query("SELECT current_setting('log_statement');", service, paths, toolchain, root).strip.should eq("none")
      admin_query("SELECT current_setting('log_min_error_statement');", service, paths, toolchain, root).strip.should eq("panic")
      admin_query("SELECT current_setting('log_parameter_max_length');", service, paths, toolchain, root).strip.should eq("0")
      admin_query("SELECT current_setting('log_parameter_max_length_on_error');", service, paths, toolchain, root).strip.should eq("0")
      db.query_one("SELECT rolconnlimit FROM pg_roles WHERE rolname = current_user", as: Int32).should eq(1)
    ensure
      db.close
    end
  end

  it "keeps development and spec credentials isolated and denies runtime DDL" do
    migration = open_database(credentials.development_migration, 1)
    begin
      migration.exec("CREATE TABLE IF NOT EXISTS durability_probe (id integer PRIMARY KEY, title text NOT NULL)")
      migration.exec("CREATE TABLE IF NOT EXISTS default_grant_probe (id bigserial PRIMARY KEY, title text NOT NULL)")
      migration.exec("TRUNCATE durability_probe")
      migration.exec("INSERT INTO durability_probe (id, title) VALUES (1, 'before restart')")
    ensure
      migration.close
    end

    runtime = open_database(credentials.development_runtime, 2)
    begin
      runtime.query_one("SELECT title FROM durability_probe WHERE id = 1", as: String).should eq("before restart")
      runtime.exec("INSERT INTO durability_probe (id, title) VALUES (2, $1)", "runtime write")
      runtime.exec("INSERT INTO default_grant_probe (title) VALUES ($1)", "runtime default")
      runtime.query_one("SELECT title FROM default_grant_probe WHERE id = 1", as: String).should eq("runtime default")
      runtime.query_one("SELECT count(*) FROM caramel_migrations", as: Int64).should eq(0_i64)
    ensure
      runtime.close
    end

    expect_database_failure(credentials.development_runtime, "CREATE TABLE runtime_must_not_create (id integer)")
    expect_database_failure(credentials.development_runtime, "ALTER TABLE durability_probe ADD COLUMN forbidden text")
    expect_database_failure(credentials.development_runtime, "DROP TABLE durability_probe")
    expect_database_failure(credentials.development_runtime, "INSERT INTO caramel_migrations (version, name, checksum) VALUES (99, 'forbidden', 'forbidden')")
    expect_database_failure(credentials.spec_runtime, "CREATE TABLE spec_runtime_must_not_create (id integer)")
    wrong_password = credentials.development_runtime.sub(
      /postgresql:\/\/[^:]+:[^@]+@/,
      "postgresql://#{credentials.roles.development_runtime}:wrong-password@"
    )
    expect_database_failure(wrong_password, "SELECT 1")

    spec_as_dev = credentials.spec_runtime.sub("/#{credentials.spec_database}?", "/#{credentials.development_database}?")
    expect_database_failure(spec_as_dev, "SELECT 1")
    spec_migration_as_dev = credentials.spec_migration.sub("/#{credentials.spec_database}?", "/#{credentials.development_database}?")
    expect_database_failure(spec_migration_as_dev, "SELECT 1")
  end

  it "retains data across a managed restart" do
    service.restart
    db = open_database(credentials.development_runtime, 2)
    begin
      db.query_one("SELECT title FROM durability_probe WHERE id = 2", as: String).should eq("runtime write")
    ensure
      db.close
    end
  end

  it "repairs retained configuration overrides while preserving the running cluster" do
    config = File.join(paths.postgres_data, "postgresql.conf")
    original = File.read(config)
    begin
      File.open(config, "a") do |file|
        file << "\n# test override that must not survive Latte reconciliation\nlisten_addresses = '*'\nmax_connections = 63\n"
      end
      service.start
      service.ready?.should be_true
      db = open_database(credentials.development_migration, 1)
      begin
        db.query_one("SELECT current_setting('listen_addresses')", as: String).should eq("")
        db.query_one("SELECT current_setting('max_connections')", as: String).should eq("64")
      ensure
        db.close
      end
    ensure
      File.write(config, original)
      File.chmod(config, 0o600)
    end
  end

  it "does not write secret bearing failed SQL into the private PostgreSQL log" do
    password = admin_password(service)
    passfile = File.join(root, "admin-log-regression.pgpass")
    File.write(passfile, "*:*:*:#{Caramel::Latte::Postgres::ADMIN_USER}:#{password}\n")
    File.chmod(passfile, 0o600)
    sentinel = "latte-secret-#{Random::Secure.hex(16)}"
    missing_role = "caramel_log_probe_#{Random::Secure.hex(8)}"
    begin
      result = Caramel::Latte::ProcessRunner.run(
        [toolchain.psql, "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-h", paths.postgres_socket_dir,
         "-U", Caramel::Latte::Postgres::ADMIN_USER, "-d", "postgres"],
        input: "ALTER ROLE #{Caramel::Latte::Postgres.quote_identifier(missing_role)} PASSWORD '#{sentinel}';\n",
        env: toolchain.environment({"PGPASSFILE" => passfile}),
        timeout: 10.seconds,
        output_limit: 16 * 1024,
      )
      result.success?.should be_false
      result.diagnostic.should_not contain(sentinel)
      sleep 100.milliseconds
      log = File.join(paths.logs_dir, "postgres.log")
      File.read(log).should_not contain(sentinel)
    ensure
      File.delete(passfile) if File.exists?(passfile)
    end
  end

  it "creates private, resumable credential material without rotating passwords" do
    path = service.credentials_path(site)
    first = File.read(path)
    File.info(path).permissions.value.should eq(0o600)
    first.should contain(site.id)
    first.should_not contain("registry")
    repeated = service.provision(site)
    File.read(path).should eq(first)
    repeated.development_runtime.should eq(credentials.development_runtime)
    File.info(service.admin_secret_path).permissions.value.should eq(0o600)
  end

  it "backs up and restores owned data with the pinned PostgreSQL tools" do
    backup = File.join(root, "owned-backup.dump")
    service.backup(site, backup)
    File.info(backup).permissions.value.should eq(0o600)

    migration = open_database(credentials.development_migration, 1)
    begin
      migration.exec("DROP TABLE durability_probe")
    ensure
      migration.close
    end
    service.restore(site, backup)

    runtime = open_database(credentials.development_runtime, 1)
    begin
      runtime.query_one("SELECT title FROM durability_probe WHERE id = 1", as: String).should eq("before restart")
    ensure
      runtime.close
    end
  end

  it "refuses a wrong major without changing the owned data directory" do
    service.stop
    version = File.join(paths.postgres_data, "PG_VERSION")
    original = File.read(version)
    File.write(version, "17\n")
    begin
      expect_raises(Caramel::Latte::Postgres::WrongMajor) { service.start }
      File.read(version).should eq("17\n")
    ensure
      File.write(version, original)
      service.start
    end
  end
end

Spec.after_suite do
  begin
    service.stop
  rescue
  end
end
