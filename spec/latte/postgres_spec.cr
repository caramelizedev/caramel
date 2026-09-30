require "spec"
require "file_utils"
require "../../src/latte/postgres"

private def postgres_unit_root : String
  root = File.join(Dir.tempdir, "caramel-latte-postgres-unit-#{Random::Secure.hex(8)}")
  Dir.mkdir(root, 0o700)
  root
end

private def remove_postgres_unit_root(root : String)
  FileUtils.rm_rf(root)
end

# Writes an owner-only executable at *relative* under the root's installs.
private def install_tool(root : String, relative : String, content : String) : Nil
  path = File.join(root, "data", "installs", relative)
  Dir.mkdir_p(File.dirname(path), mode: 0o700)
  File.write(path, content)
  File.chmod(path, 0o700)
end

describe Caramel::Latte::Toolchain do
  it "resolves every managed executable from the explicit root" do
    root = postgres_unit_root
    begin
      scripts = %w[
        conda-postgresql/18.6/bin/postgres
        conda-postgresql/18.6/bin/initdb
        conda-postgresql/18.6/bin/pg_ctl
        conda-postgresql/18.6/bin/psql
        conda-postgresql/18.6/bin/pg_dump
        conda-postgresql/18.6/bin/pg_restore
        conda-openssl/3.6.4/bin/openssl
      ]
      scripts.each { |relative| install_tool(root, relative, "#!/bin/sh\n") }
      install_tool(root, "aqua-caddyserver-caddy/2.11.4/caddy", "")
      install_tool(root, "github-coredns-coredns/1.14.7/coredns", "")

      tools = Caramel::Latte::Toolchain.new(root)
      tools.root.should eq(File.realpath(root))
      installs = File.join(File.realpath(root), "data/installs")
      tools.postgres.should eq(File.join(installs, "conda-postgresql/18.6/bin/postgres"))
      tools.pg_ctl.should end_with("/conda-postgresql/18.6/bin/pg_ctl")
      tools.pg_dump.should end_with("/conda-postgresql/18.6/bin/pg_dump")
      tools.pg_restore.should end_with("/conda-postgresql/18.6/bin/pg_restore")
      tools.openssl.should end_with("/conda-openssl/3.6.4/bin/openssl")
      tools.caddy.should end_with("/aqua-caddyserver-caddy/2.11.4/caddy")
      tools.coredns.should end_with("/github-coredns-coredns/1.14.7/coredns")
    ensure
      remove_postgres_unit_root(root)
    end
  end

  it "does not fall back to a globally installed executable" do
    root = postgres_unit_root
    begin
      tools = Caramel::Latte::Toolchain.new(root)
      expect_raises(Caramel::Latte::Toolchain::Unavailable) { tools.postgres }
    ensure
      remove_postgres_unit_root(root)
    end
  end

  it "rejects a PostgreSQL patch version outside the pinned 18.6 toolchain" do
    root = postgres_unit_root
    begin
      path = File.join(root, "data", "installs", "conda-postgresql", "18.6", "bin", "postgres")
      Dir.mkdir_p(File.dirname(path), mode: 0o700)
      File.write(path, "#!/bin/sh\necho 'postgres (PostgreSQL) 18.5'\n")
      File.chmod(path, 0o700)
      tools = Caramel::Latte::Toolchain.new(root)
      expect_raises(Caramel::Latte::Toolchain::VersionMismatch) { tools.verify_postgres_version! }
    ensure
      remove_postgres_unit_root(root)
    end
  end
end

describe Caramel::Latte::ProcessRunner do
  it "kills a command that exceeds its deadline and bounds diagnostics" do
    result = Caramel::Latte::ProcessRunner.run(
      ["/bin/sh", "-c", "sleep 2"],
      timeout: 50.milliseconds,
    )
    result.timed_out?.should be_true
    result.status.success?.should be_false
  end

  it "reaps a direct child after an ordinary timeout" do
    root = postgres_unit_root
    pid_path = File.join(root, "timed-out.pid")
    result = Caramel::Latte::ProcessRunner.run(
      ["/bin/sh", "-c", "echo $$ > #{pid_path}; exec /bin/sleep 2"],
      timeout: 50.milliseconds,
    )
    result.timed_out?.should be_true
    pid = File.read(pid_path).strip.to_i64
    deadline = Time.instant + 2.seconds
    while Process.exists?(pid) && Time.instant < deadline
      sleep 20.milliseconds
    end
    Process.exists?(pid).should be_false
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "applies one operation budget across successive commands" do
    expect_raises(Caramel::Latte::DeadlineExceeded) do
      Caramel::Latte::OperationDeadline.run(100.milliseconds) do
        first = Caramel::Latte::ProcessRunner.run(["/bin/sleep", "2"], timeout: 5.seconds)
        first.timed_out?.should be_true
        Caramel::Latte::ProcessRunner.run(["/bin/echo", "must-not-launch"], timeout: 5.seconds)
      end
    end
  end

  it "does not include environment passwords in the returned command diagnostic" do
    result = Caramel::Latte::ProcessRunner.run(
      ["/bin/sh", "-c", "echo secret >&2; exit 7"],
      env: {"PGPASSWORD" => "must-not-be-reported"},
      timeout: 2.seconds,
    )
    result.status.exit_code.should eq(7)
    result.stderr.should eq("secret\n")
    result.diagnostic.should_not contain("must-not-be-reported")
  end

  it "drains noisy output without retaining more than the configured bound" do
    result = Caramel::Latte::ProcessRunner.run(
      ["/bin/sh", "-c", "yes x | head -c 100000"],
      timeout: 2.seconds,
      output_limit: 64,
    )
    result.success?.should be_true
    result.stdout.bytesize.should be <= 64
  end
end

describe Caramel::Latte::ManagedChild do
  it "records an exact live identity and returns without waiting for lifecycle readiness" do
    root = postgres_unit_root
    record = File.join(root, "child.json")
    log = File.join(root, "child.log")
    child = Caramel::Latte::ManagedChild.new("sleep", "/bin/sleep", ["5"], record, log)
    started = Time.instant
    identity = child.start
    (Time.instant - started).should be < 2.seconds
    identity.pid.should be > 1
    child.running?.should be_true
    child.stop.should be_true
    child.running?.should be_false
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "rejects a symlinked log before launching a child" do
    root = postgres_unit_root
    target = File.join(root, "real.log")
    log = File.join(root, "child.log")
    File.write(target, "private\n")
    File.symlink(target, log)
    record = File.join(root, "child.json")
    child = Caramel::Latte::ManagedChild.new("sleep", "/bin/sleep", ["5"], record, log)
    expect_raises(Caramel::Latte::OwnershipError) { child.start }
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "adopts one exact unrecorded child after a record write window" do
    root = postgres_unit_root
    record = File.join(root, "child.json")
    log = File.join(root, "child.log")
    stray = Process.new(["/bin/sleep", "5"])
    child = Caramel::Latte::ManagedChild.new("sleep", "/bin/sleep", ["5"], record, log)
    identity = child.start
    identity.pid.should eq(stray.pid)
    child.stop.should be_true
    stray.wait
  ensure
    begin
      stray.terminate(graceful: false) if stray && !stray.terminated?
      stray.wait if stray
    rescue
    end
    FileUtils.rm_rf(root) if root
  end

  it "refuses ambiguous unrecorded children without signaling either one" do
    root = postgres_unit_root
    record = File.join(root, "child.json")
    log = File.join(root, "child.log")
    # ameba:disable Lint/UselessAssign -- read by the ensure below
    first : Process? = nil
    # ameba:disable Lint/UselessAssign -- read by the ensure below
    second : Process? = nil
    first = Process.new(["/bin/sleep", "5"])
    second = Process.new(["/bin/sleep", "5"])
    child = Caramel::Latte::ManagedChild.new("sleep", "/bin/sleep", ["5"], record, log)
    expect_raises(Caramel::Latte::OwnershipError) { child.start }
    Process.exists?(first.pid).should be_true
    Process.exists?(second.pid).should be_true
  ensure
    [first, second].each do |stray|
      process = stray.not_nil!
      process.terminate(graceful: false) unless process.terminated?
      process.wait
    rescue
    end
    FileUtils.rm_rf(root) if root
  end
end

describe Caramel::Latte::Postgres do
  it "derives safe identifiers and private Unix socket URLs from a site id" do
    id = "0123456789abcdef"
    names = Caramel::Latte::Postgres.database_names(id)
    names.development.should eq("caramel_dev_0123456789abcdef")
    names.spec.should eq("caramel_spec_0123456789abcdef")
    names.development.bytesize.should be <= 63

    url = Caramel::Latte::Postgres.connection_url(
      "caramel_runtime_#{id}",
      "secret",
      names.development,
      "/private/tmp/caramel-test/postgres",
    )
    url.should start_with("postgresql://caramel_runtime_#{id}:secret@/")
    url.should contain("host=%2Fprivate%2Ftmp%2Fcaramel-test%2Fpostgres")
    url.should_not contain("127.0.0.1")
  end

  it "refuses to start an empty cluster beside another major's data, and keeps that data" do
    tools = postgres_unit_root
    state = "/private/tmp/caramel-latte-majors-#{Random::Secure.hex(8)}"
    Dir.mkdir(state, 0o700)
    begin
      bin = File.join(tools, "data/installs/conda-postgresql/18.6/bin")
      Dir.mkdir_p(bin, mode: 0o700)
      marker = File.join(tools, "initdb-ran")
      scripts = {
        "postgres" => "echo 'postgres (PostgreSQL) 18.6'",
        "initdb"   => "touch '#{marker}'",
      }
      scripts.each do |name, body|
        File.write(File.join(bin, name), "#!/bin/sh\n#{body}\n")
        File.chmod(File.join(bin, name), 0o700)
      end
      previous = File.join(state, "services/postgres/17/data")
      Dir.mkdir_p(previous, mode: 0o700)
      File.write(File.join(previous, "PG_VERSION"), "17\n")
      paths = Caramel::Latte::Paths.new(state)
      service = Caramel::Latte::Postgres.new(paths, Caramel::Latte::Toolchain.new(tools))
      refusal = "Latte's databases are in PostgreSQL 17, " \
                "but Caramel #{Caramel::VERSION} uses PostgreSQL 18"
      expect_raises(Caramel::Latte::Postgres::WrongMajor, refusal) { service.start }
      File.exists?(marker).should be_false
      Dir.children(File.join(state, "services/postgres/18/data")).should be_empty
      File.read(File.join(previous, "PG_VERSION")).should eq("17\n")
    ensure
      remove_postgres_unit_root(tools)
      FileUtils.rm_rf(state)
    end
  end

  it "quotes generated SQL identifiers and literals" do
    Caramel::Latte::Postgres.quote_identifier("safe_name").should eq("\"safe_name\"")
    quoted = %("name""with""quotes")
    Caramel::Latte::Postgres.quote_identifier(%(name"with"quotes)).should eq(quoted)
    Caramel::Latte::Postgres.quote_literal("don't").should eq("'don''t'")
  end

  it "redacts credential URLs and passwords from inspection" do
    id = "0123456789abcdef"
    names = Caramel::Latte::Postgres.database_names(id)
    roles = Caramel::Latte::Postgres.role_names(id)
    credentials = Caramel::Latte::Postgres::Credentials.new(
      "postgresql://runtime:secret@/dev",
      "postgresql://migration:secret@/dev",
      "postgresql://runtime:secret@/spec",
      "postgresql://migration:secret@/spec",
      names.development,
      names.spec,
      roles,
      names,
    )
    credentials.inspect.should_not contain("secret")
    credentials.to_s.should_not contain("postgresql://")
  end

  it "accepts only short lowercase branch names " \
     "and derives an identifier within PostgreSQL's limit" do
    id = "0123456789abcdef"
    longest = "a" + "b" * 30
    database = Caramel::Latte::Postgres.branch_database(id, longest)
    database.should eq("caramel_branch_0123456789abcdef_#{longest}")
    database.bytesize.should eq(63)
    diff = "caramel_branch_0123456789abcdef_diff_1a2b"
    Caramel::Latte::Postgres.branch_database(id, "diff_1a2b").should eq(diff)
    rejected = [
      longest + "c", "", "1diff", "_diff", "Diff", "feat-stripe", "a b", "a\"b", "é",
    ]
    rejected.each do |name|
      expect_raises(ArgumentError, "branch name must be lowercase") do
        Caramel::Latte::Postgres.branch_database(id, name)
      end
    end
    expect_raises(ArgumentError) { Caramel::Latte::Postgres.branch_database("not-a-site", "diff") }
  end

  it "guards the source by refusing connections " \
     "and terminating every other backend before cloning" do
    source = "caramel_dev_0123456789abcdef"
    branch = "caramel_branch_0123456789abcdef_diff"
    migration = "caramel_dev_migration_0123456789abcdef"
    runtime = "caramel_dev_runtime_0123456789abcdef"
    guard = Caramel::Latte::Postgres.branch_guard_sql(source)
    guard.lines.map(&.strip).should eq([
      %(ALTER DATABASE "#{source}" WITH ALLOW_CONNECTIONS false;),
      "SELECT count(pg_terminate_backend(pid, 5000)) FROM pg_stat_activity " \
      "WHERE datname = '#{source}' AND pid <> pg_backend_pid();",
    ])
    clone = %(CREATE DATABASE "#{branch}" WITH TEMPLATE "#{source}" ) +
            %(OWNER "#{migration}" STRATEGY FILE_COPY;)
    Caramel::Latte::Postgres.branch_clone_sql(source, branch, migration).should eq(clone)
    release = %(ALTER DATABASE "#{source}" WITH ALLOW_CONNECTIONS true;)
    Caramel::Latte::Postgres.branch_release_sql(source).should eq(release)
    access = Caramel::Latte::Postgres.branch_access_sql(branch, migration, runtime)
    revoke = %(REVOKE CONNECT, TEMPORARY, CREATE ON DATABASE "#{branch}" FROM PUBLIC;)
    grant = %(GRANT CONNECT ON DATABASE "#{branch}" TO "#{migration}", "#{runtime}";)
    access.should contain(revoke)
    access.should contain(grant)
  end

  it "redacts branch URLs from inspection" do
    branch = Caramel::Latte::Postgres::Branch.new(
      name: "diff",
      database: "caramel_branch_0123456789abcdef_diff",
      migration_url: "postgresql://migration:secret@/b",
      runtime_url: "postgresql://runtime:secret@/b",
    )
    branch.inspect.should_not contain("secret")
    branch.to_s.should contain("caramel_branch_0123456789abcdef_diff")
  end
end
