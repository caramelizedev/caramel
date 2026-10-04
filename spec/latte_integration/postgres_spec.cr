require "spec"
require "file_utils"
require "json"
require "random/secure"
require "socket"
require "../../src/sugar_orm"
require "../../src/caramel/database"
require "../../src/latte/postgres"

root = ENV["CARAMEL_LATTE_ROOT"]? ||
       raise "CARAMEL_LATTE_ROOT is required; run scripts/check latte-postgres"
project = ENV["CARAMEL_LATTE_PROJECT"]? || raise "CARAMEL_LATTE_PROJECT is required"
paths = Caramel::Latte::Paths.new(root)
toolchain = Caramel::Latte::Toolchain.for_checkout
service = Caramel::Latte::Postgres.new(paths, toolchain)
site = Caramel::Latte::Site.new("bookshelf", project)
credentials = service.provision(site)
# The administrator's answer to *sql*, trimmed.
admin = ->(sql : String) { admin_query(sql, service, paths, toolchain, root).strip }

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

# The title of durability_probe row *id*, as *db* reads it.
private def durability_title(db : DB::Database, id : Int32) : String
  db.query_one("SELECT title FROM durability_probe WHERE id = #{id}", as: String)
end

# *url* with its database *from* replaced by *to*.
private def retarget(url : String, from : String, to : String) : String
  url.sub("/#{from}?", "/#{to}?")
end

describe "Latte managed PostgreSQL" do
  it "uses PostgreSQL 18, UTF8/UTC, no TCP listener, and a fixed connection cap" do
    service.running?.should be_true
    service.ready?.should be_true
    setting = ->(name : String) { admin.call("SELECT current_setting('#{name}');") }
    encoding = "SELECT pg_encoding_to_char(encoding) FROM pg_database " \
               "WHERE datname = current_database()"
    limit = "SELECT rolconnlimit FROM pg_roles WHERE rolname = current_user"
    db = open_database(credentials.development_migration, 1)
    begin
      db.query_one("SELECT current_setting('server_version') LIKE '18.6%'", as: Bool).should be_true
      db.query_one(encoding, as: String).should eq("UTF8")
      db.query_one("SHOW timezone", as: String).should eq("UTC")
      db.query_one("SELECT current_setting('listen_addresses')", as: String).should eq("")
      setting.call("unix_socket_directories").should eq(paths.postgres_socket_dir)
      setting.call("unix_socket_permissions").should eq("0700")
      db.query_one("SELECT current_setting('max_connections')", as: String).should eq("64")
      setting.call("password_encryption").should eq("scram-sha-256")
      setting.call("log_statement").should eq("none")
      setting.call("log_min_error_statement").should eq("panic")
      setting.call("log_parameter_max_length").should eq("0")
      setting.call("log_parameter_max_length_on_error").should eq("0")
      db.query_one(limit, as: Int32).should eq(1)
      db.query_one("SHOW file_copy_method", as: String).should eq("clone")
    ensure
      db.close
    end
  end

  it "preloads pg_stat_statements and auto_explain" do
    admin.call("SHOW shared_preload_libraries;").should eq("pg_stat_statements,auto_explain")
    admin.call("SHOW auto_explain.log_min_duration;").should eq("250ms")
    admin.call("SHOW auto_explain.log_parameter_max_length;").should eq("0")
  end

  it "keeps pg_stat_statements in its own schema of the development database only" do
    where = "SELECT extnamespace::regnamespace::text FROM pg_extension " \
            "WHERE extname = 'pg_stat_statements'"
    runtime = open_database(credentials.development_runtime, 1)
    begin
      runtime.query_one(where, as: String).should eq("caramel_stats")
      runtime.query_one("SELECT count(*) FROM caramel_stats.pg_stat_statements", as: Int64)
        .should be >= 0_i64
    ensure
      runtime.close
    end
    spec = open_database(credentials.spec_runtime, 1)
    begin
      spec.query_all(where, as: String).should be_empty
    ensure
      spec.close
    end
    migration = open_database(credentials.development_migration, 1)
    begin
      names = SugarORM::Introspection.read(migration).tables.map(&.name)
      names.none?(&.includes?("pg_stat_statements")).should be_true
    ensure
      migration.close
    end
  end

  it "stays idempotent when provisioned again" do
    again = service.provision(site)
    again.development_runtime.should eq(credentials.development_runtime)
    runtime = open_database(credentials.development_runtime, 1)
    begin
      count = "SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements'"
      runtime.query_one(count, as: Int64).should eq(1_i64)
    ensure
      runtime.close
    end
  end

  it "keeps development and spec credentials isolated and denies runtime DDL" do
    durability = "CREATE TABLE IF NOT EXISTS durability_probe " \
                 "(id integer PRIMARY KEY, title text NOT NULL)"
    default_grant = "CREATE TABLE IF NOT EXISTS default_grant_probe " \
                    "(id bigserial PRIMARY KEY, title text NOT NULL)"
    migration = open_database(credentials.development_migration, 1)
    begin
      migration.exec(durability)
      migration.exec(default_grant)
      migration.exec("TRUNCATE durability_probe")
      migration.exec("INSERT INTO durability_probe (id, title) VALUES (1, 'before restart')")
    ensure
      migration.close
    end

    granted = "SELECT title FROM default_grant_probe WHERE id = 1"
    runtime = open_database(credentials.development_runtime, 2)
    begin
      durability_title(runtime, 1).should eq("before restart")
      runtime.exec("INSERT INTO durability_probe (id, title) VALUES (2, $1)", "runtime write")
      runtime.exec("INSERT INTO default_grant_probe (title) VALUES ($1)", "runtime default")
      runtime.query_one(granted, as: String).should eq("runtime default")
      runtime.query_one("SELECT count(*) FROM caramel_migrations", as: Int64).should eq(0_i64)
    ensure
      runtime.close
    end

    runtime_url = credentials.development_runtime
    forged = "INSERT INTO caramel_migrations (version, name, checksum) " \
             "VALUES (99, 'forbidden', 'forbidden')"
    spec_ddl = "CREATE TABLE spec_runtime_must_not_create (id integer)"
    expect_database_failure(runtime_url, "CREATE TABLE runtime_must_not_create (id integer)")
    expect_database_failure(runtime_url, "ALTER TABLE durability_probe ADD COLUMN forbidden text")
    expect_database_failure(runtime_url, "DROP TABLE durability_probe")
    expect_database_failure(runtime_url, forged)
    expect_database_failure(credentials.spec_runtime, spec_ddl)
    wrong_password = credentials.development_runtime.sub(
      /postgresql:\/\/[^:]+:[^@]+@/,
      "postgresql://#{credentials.roles.development_runtime}:wrong-password@"
    )
    expect_database_failure(wrong_password, "SELECT 1")

    spec, development = credentials.spec_database, credentials.development_database
    spec_as_dev = retarget(credentials.spec_runtime, spec, development)
    expect_database_failure(spec_as_dev, "SELECT 1")
    spec_migration_as_dev = retarget(credentials.spec_migration, spec, development)
    expect_database_failure(spec_migration_as_dev, "SELECT 1")
  end

  it "retains data across a managed restart" do
    service.restart
    db = open_database(credentials.development_runtime, 2)
    begin
      durability_title(db, 2).should eq("runtime write")
    ensure
      db.close
    end
  end

  it "adopts a postmaster another toolchain's build of this major started, as after an upgrade" do
    service.stop
    data = paths.postgres_data(Caramel::Latte::Postgres::MAJOR)
    pid_file = File.join(data, "postmaster.pid")
    # The same PostgreSQL 18 build at another path, as another toolchain release has it.
    other = File.join(root, "other-toolchain/bin/postgres")
    Dir.mkdir_p(File.dirname(other), 0o700)
    File.symlink(toolchain.postgres, other) unless File.symlink?(other)
    pg_ctl = ->(arguments : Array(String)) do
      Caramel::Latte::ProcessRunner.run(
        [toolchain.pg_ctl, "-D", data] + arguments,
        env: toolchain.environment,
        timeout: 30.seconds,
      )
    end
    log = File.join(root, "other-toolchain/postgres.log")
    options = "-k #{paths.postgres_socket_dir} " \
              "-c listen_addresses='' -c unix_socket_permissions=0700"
    started = pg_ctl.call(["-p", other, "-l", log, "-o", options, "-w", "start"])
    started.success?.should be_true
    adopted = File.read_lines(pid_file).first
    begin
      service.start
      File.read_lines(pid_file).first.should eq(adopted)
      db = open_database(credentials.development_runtime, 1)
      begin
        durability_title(db, 2).should eq("runtime write")
      ensure
        db.close
      end
      service.restart
      File.read_lines(pid_file).first.should_not eq(adopted)
      service.ready?.should be_true
    ensure
      # A postmaster Latte refused would otherwise outlive the check.
      pg_ctl.call(["-m", "fast", "-w", "stop"]) unless service.running?
    end
  end

  it "repairs retained configuration overrides while preserving the running cluster" do
    config = File.join(paths.postgres_data(Caramel::Latte::Postgres::MAJOR), "postgresql.conf")
    original = File.read(config)
    override = <<-CONF

      # test override that must not survive Latte reconciliation
      listen_addresses = '*'
      max_connections = 63

      CONF
    begin
      File.open(config, "a") do |file|
        file << override
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
    role = Caramel::Latte::Postgres.quote_identifier(missing_role)
    begin
      result = Caramel::Latte::ProcessRunner.run(
        [toolchain.psql, "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-h", paths.postgres_socket_dir,
         "-U", Caramel::Latte::Postgres::ADMIN_USER, "-d", "postgres"],
        input: "ALTER ROLE #{role} PASSWORD '#{sentinel}';\n",
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
      durability_title(runtime, 1).should eq("before restart")
    ensure
      runtime.close
    end
  end

  it "restores over a database that holds partitioned tables" do
    partitioned = "CREATE TABLE partition_probe " \
                  "(id bigint NOT NULL, day date NOT NULL, title text NOT NULL, " \
                  "PRIMARY KEY (id, day)) PARTITION BY RANGE (day)"
    year = "CREATE TABLE partition_probe_2026 PARTITION OF partition_probe " \
           "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')"
    migration = open_database(credentials.development_migration, 1)
    begin
      migration.exec(partitioned)
      migration.exec(year)
      migration.exec("CREATE INDEX partition_probe_title ON partition_probe (title)")
      migration.exec("INSERT INTO partition_probe VALUES (1, '2026-09-27', 'kept')")
    ensure
      migration.close
    end
    backup = File.join(root, "partitioned-backup.dump")
    service.backup(site, backup)
    migration = open_database(credentials.development_migration, 1)
    begin
      migration.exec("DELETE FROM partition_probe")
    ensure
      migration.close
    end
    service.restore(site, backup)
    runtime = open_database(credentials.development_runtime, 1)
    begin
      runtime.query_all("SELECT title FROM partition_probe", as: String).should eq(["kept"])
      durability_title(runtime, 1).should eq("before restart")
    ensure
      runtime.close
    end
  end

  it "branches the development database behind the connection guard, " \
     "then lists and drops the branch" do
    source = credentials.development_database
    migration = open_database(credentials.development_migration, 1)
    begin
      migration.exec("CREATE TABLE IF NOT EXISTS branch_probe (title text NOT NULL)")
      migration.exec("TRUNCATE branch_probe")
      migration.exec("INSERT INTO branch_probe VALUES ('from development')")
    ensure
      migration.close
    end
    held = open_database(credentials.development_runtime, 1)
    held_pid = held.query_one("SELECT pg_backend_pid()", as: Int32)
    branch = service.create_branch(site, "feature_probe")
    begin
      backends = "SELECT count(*) FROM pg_stat_activity WHERE pid = #{held_pid};"
      connectable = "SELECT datallowconn FROM pg_database WHERE datname = '#{source}';"
      admin.call(backends).should eq("0")
      admin.call(connectable).should eq("t")
      branch.database.should eq("caramel_branch_#{site.id}_feature_probe")
      service.list_branches(site).should eq(["feature_probe"])
      expect_raises(Caramel::Latte::Postgres::BranchExists) do
        service.create_branch(site, "feature_probe")
      end

      writer = open_database(branch.migration_url, 1)
      begin
        writer.query_one("SELECT current_database()", as: String).should eq(branch.database)
        writer.query_one("SHOW timezone", as: String).should eq("UTC")
        writer.exec("INSERT INTO branch_probe VALUES ('on the branch')")
        writer.exec("CREATE TABLE branch_only (id integer)")
      ensure
        writer.close
      end
      ordered = "SELECT title FROM branch_probe ORDER BY title"
      reader = open_database(branch.runtime_url, 1)
      begin
        reader.query_all(ordered, as: String).should eq(["from development", "on the branch"])
      ensure
        reader.close
      end
      development = open_database(credentials.development_runtime, 1)
      begin
        titles = development.query_all("SELECT title FROM branch_probe", as: String)
        titles.should eq(["from development"])
        development.query_one("SELECT to_regclass('branch_only')::text", as: String?).should be_nil
      ensure
        development.close
      end
      spec = credentials.spec_database
      spec_on_branch = retarget(credentials.spec_runtime, spec, branch.database)
      expect_database_failure(spec_on_branch, "SELECT 1")
    ensure
      held.close
      service.drop_branch(site, "feature_probe").should be_true
    end
    service.list_branches(site).should be_empty
    service.drop_branch(site, "feature_probe").should be_false
  end

  it "re-allows connections to the source database when a guarded operation fails, " \
     "and after a crash" do
    source = credentials.development_database
    connectable = "SELECT datallowconn FROM pg_database WHERE datname = '#{source}';"
    allowed = -> { admin.call(connectable) }
    expect_raises(Exception, "clone failed") do
      service.guard_connections(source) do
        allowed.call.should eq("f")
        expect_database_failure(credentials.development_runtime, "SELECT 1")
        raise "clone failed"
      end
    end
    allowed.call.should eq("t")
    db = open_database(credentials.development_runtime, 1)
    begin
      db.query_one("SELECT count(*) FROM branch_probe", as: Int64).should eq(1_i64)
    ensure
      db.close
    end

    locked = "ALTER DATABASE #{Caramel::Latte::Postgres.quote_identifier(source)} " \
             "WITH ALLOW_CONNECTIONS false;"
    admin.call(locked)
    service.release_guards
    allowed.call.should eq("t")
  end

  it "clones, resets and drops Corretto test workers " \
     "from the migrated spec database behind the guard" do
    template = open_database(credentials.spec_migration, 1)
    begin
      template.exec("CREATE TABLE IF NOT EXISTS worker_probe (title text NOT NULL)")
      template.exec("TRUNCATE worker_probe")
      template.exec("INSERT INTO worker_probe VALUES ('migrated')")
    ensure
      template.close
    end
    held = open_database(credentials.spec_runtime, 1)
    held_pid = held.query_one("SELECT pg_backend_pid()", as: Int32)
    first = service.reset_test_worker(site, 1)
    second = service.reset_test_worker(site, 2)
    begin
      spec = credentials.spec_database
      backends = "SELECT count(*) FROM pg_stat_activity WHERE pid = #{held_pid};"
      connectable = "SELECT datallowconn FROM pg_database WHERE datname = '#{spec}';"
      admin.call(backends).should eq("0")
      admin.call(connectable).should eq("t")
      first.database.should eq("#{credentials.spec_database}_w1")
      second.database.should eq("#{credentials.spec_database}_w2")

      # Each worker's migration role may hold a connection at the same time.
      first_migration = open_database(first.migration_url, 1)
      second_migration = open_database(second.migration_url, 1)
      begin
        first_migration.exec("CREATE TABLE leaked_ddl (id integer)")
        current = second_migration.query_one("SELECT current_database()", as: String)
        current.should eq(second.database)
      ensure
        first_migration.close
        second_migration.close
      end
      ordered = "SELECT title FROM worker_probe ORDER BY title"
      runtime = open_database(first.runtime_url, 1)
      begin
        runtime.query_one("SHOW timezone", as: String).should eq("UTC")
        runtime.exec("INSERT INTO worker_probe VALUES ('dirty')")
        runtime.query_all(ordered, as: String).should eq(["dirty", "migrated"])
        expect_database_failure(first.runtime_url, "CREATE TABLE runtime_ddl (id integer)")
      ensure
        runtime.close
      end

      reset = service.reset_test_worker(site, 1)
      reset.runtime_url.should eq(first.runtime_url)
      clean = open_database(reset.runtime_url, 1)
      begin
        clean.query_all("SELECT title FROM worker_probe", as: String).should eq(["migrated"])
        clean.query_one("SELECT to_regclass('leaked_ddl')::text", as: String?).should be_nil
      ensure
        clean.close
      end
      development = credentials.development_database
      dev_on_worker = retarget(credentials.development_runtime, development, first.database)
      expect_database_failure(dev_on_worker, "SELECT 1")
      template = open_database(credentials.spec_runtime, 1)
      begin
        template.query_all("SELECT title FROM worker_probe", as: String).should eq(["migrated"])
      ensure
        template.close
      end
      out_of_range = "test worker index must be 1 to 8"
      expect_raises(ArgumentError, out_of_range) { service.reset_test_worker(site, 9) }
      expect_raises(ArgumentError, out_of_range) { service.drop_test_worker(site, 0) }
    ensure
      held.close
      service.drop_test_worker(site, 1).should be_true
      service.drop_test_worker(site, 2).should be_true
    end
    service.drop_test_worker(site, 1).should be_false
    workers = "SELECT count(*) FROM pg_database " \
              "WHERE datname LIKE '#{credentials.spec_database}_w%';"
    admin.call(workers).should eq("0")
  end

  it "refuses a wrong major without changing the owned data directory" do
    service.stop
    version = File.join(paths.postgres_data(Caramel::Latte::Postgres::MAJOR), "PG_VERSION")
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
  service.stop
rescue
end
