require "../config/application"

USAGE = "Usage: @@SHARD@@ serve|seed|routes|schema|drift|migrate [--dev-override]|lint [--dev-override]"

command = ARGV.shift? || "help"
dev_override = ARGV == ["--dev-override"] && {"migrate", "lint"}.includes?(command)
unless ARGV.empty? || dev_override
  STDERR.puts(USAGE)
  exit 2
end
case command
when "routes"
  width = App::AppRouter.routes.max_of(&.path.size)
  App::AppRouter.routes.each do |entry|
    puts "#{entry.method.ljust(7)} #{entry.path.ljust(width)}  #{entry.action}#{entry.contract.empty? ? "" : "  " + entry.contract}"
  end
  exit
when "schema"
  puts SugarORM::Catalog.to_json(SugarORM::Catalog.declared)
  exit
when "serve", "seed", "migrate", "lint", "drift"
else
  puts USAGE
  exit(command == "help" ? 0 : 2)
end

database_url = App.database_url(migration: command == "migrate")
if expected = ENV["CARAMEL_EXPECTED_DATABASE_URL"]?
  abort("Database connection differs from the verified launcher configuration") unless database_url == expected
elsif ENV["CARAMEL_ENV"]? == "test"
  abort("Run specs through frappe corretto")
end
db = Caramel::Database.open(database_url)
status = 0
begin
  SugarORM::Repo.database = db
  migrator = SugarORM::Migrator.new(db, App::MIGRATIONS)
  case command
  when "migrate"
    puts "Applied #{migrator.migrate(dev_override: dev_override)} migrations."
  when "lint"
    SugarORM::Linter.enforce(migrator.lint, dev_override)
    puts "Pending migrations pass the zero-lock linter."
  when "drift"
    drift = SugarORM::Differ.diff(SugarORM::Catalog.declared, SugarORM::Introspection.read(db))
    if drift.clean?
      puts "The database matches the declared schema."
    else
      puts "The database differs from the declared schema:"
      print drift
      puts "  Remediation: run frappe db diff --name NAME, then frappe migrate."
      status = 1
    end
  when "seed"
    abort("Pending migrations. Run frappe migrate first.") unless migrator.pending.empty?
    App.seed(db)
  when "serve"
    abort("Pending migrations. Run frappe migrate first.") unless migrator.pending.empty?
    origin = ENV["APP_ORIGIN"]? || abort("APP_ORIGIN is required")
    secret = ENV["APP_SECRET"]? || abort("APP_SECRET is required")
    socket_path = ENV["CARAMEL_SOCKET"]? || abort("CARAMEL_SOCKET is required; use frappe dev")
    parent = File.info?(File.dirname(socket_path), follow_symlinks: false)
    unless parent && parent.directory? && !parent.symlink? && parent.owner_id == LibC.getuid.to_s && (parent.permissions.value & 0o077) == 0
      abort("CARAMEL_SOCKET must be in a private owned directory")
    end
    abort("Application socket is already occupied") if File.info?(socket_path, follow_symlinks: false)
    server = HTTP::Server.new([App.build(db, secret, origin)])
    server.bind_unix(socket_path)
    File.chmod(socket_path, 0o600)
    # Workers, maintenance, schedules and PubSub. Specs drain queues instead.
    cold_brew = Caramel::ColdBrew.start(database_url) unless ENV["CARAMEL_ENV"]? == "test"
    Signal::INT.trap { server.close }
    Signal::TERM.trap { server.close }
    puts "@@TITLE@@ is ready at #{origin}"
    begin
      server.listen
    ensure
      server.close unless server.closed?
      File.delete?(socket_path)
      # In-flight jobs finish; no new ones start.
      cold_brew.try(&.stop)
    end
  end
rescue ex : SugarORM::Linter::Refused | SugarORM::Migrator::Drift | SugarORM::Migrator::ConcurrentIndexFailed | Caramel::ColdBrew::ConfigurationError
  STDERR.puts(ex.message)
  status = 1
ensure
  db.close
end
exit status
