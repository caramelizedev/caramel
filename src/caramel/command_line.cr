require "http/server"
require "./application"
require "./csrf"
require "./database"
require "./cold_brew"
require "../sugar_orm"

module Caramel
  # A generated application's whole main is `Caramel.run(App)` (ADR 0016), so
  # a framework upgrade upgrades the commands Frappé runs on the application
  # binary. Call it from the project's src/ directory: its __DIR__ locates
  # the project's public/ files.
  def self.run(app : T.class, arguments : Array(String) = ARGV, source : String = __DIR__) : NoReturn forall T
    exit CommandLine.run(app, arguments, File.expand_path("..", source))
  end

  # The application's HTTP handler on a database pool: its router behind
  # CSRF protection, serving *root*/public.
  def self.build(app : T.class, db : DB::Database, secret : String, origin : String, root : String) : Application forall T
    SugarORM::Repo.database = db
    Application.new(T::AppRouter.new, CSRF.new(secret, origin), File.join(root, "public"))
  end

  module CommandLine
    USAGE = "serve|seed|routes|schema|drift|migrate [--dev-override]|lint [--dev-override]"

    # Runs one command and returns its exit status. `App` provides TITLE,
    # MIGRATIONS, AppRouter and `seed`.
    def self.run(app : T.class, arguments : Array(String), root : String) : Int32 forall T
      command = arguments.first? || "help"
      dev_override = arguments[1..]? == ["--dev-override"] && {"migrate", "lint"}.includes?(command)
      usage = "Usage: #{File.basename(PROGRAM_NAME)} #{USAGE}"
      unless arguments.size <= 1 || dev_override
        STDERR.puts(usage)
        return 2
      end
      case command
      when "routes"
        routes(T::AppRouter.routes)
      when "schema"
        puts SugarORM::Catalog.to_json(SugarORM::Catalog.declared)
        0
      when "serve", "seed", "migrate", "lint", "drift"
        with_database(command == "migrate") { |db, url| database_command(app, command, db, url, dev_override, root) }
      else
        puts usage
        command == "help" ? 0 : 2
      end
    end

    private def self.routes(entries : Array(Router::Entry)) : Int32
      width = entries.max_of?(&.path.size) || 0
      entries.each do |entry|
        puts "#{entry.method.ljust(7)} #{entry.path.ljust(width)}  #{entry.action}#{entry.contract.empty? ? "" : "  " + entry.contract}"
      end
      0
    end

    # Opens the environment's database, refusing a connection other than the
    # one Frappé verified and any spec database outside Corretto.
    private def self.with_database(migration : Bool, & : DB::Database, String -> Int32) : Int32
      url = Database.url(migration: migration)
      if expected = ENV["CARAMEL_EXPECTED_DATABASE_URL"]?
        abort("Database connection differs from the verified launcher configuration") unless url == expected
      elsif ENV["CARAMEL_ENV"]? == "test"
        abort("Run specs through frappe corretto")
      end
      db = Database.open(url)
      begin
        SugarORM::Repo.database = db
        yield db, url
      rescue ex : SugarORM::Linter::Refused
        # frappe migrate sets CARAMEL_DIAGNOSTICS=mrdp for coding agents.
        STDERR.print(ENV["CARAMEL_DIAGNOSTICS"]? == "mrdp" ? ex.to_mrdp : "#{ex.message}\n")
        1
      rescue ex : SugarORM::Migrator::Drift | SugarORM::Migrator::ConcurrentIndexFailed | ColdBrew::ConfigurationError
        STDERR.puts(ex.message)
        1
      ensure
        db.close
      end
    end

    private def self.database_command(app : T.class, command : String, db : DB::Database, url : String, dev_override : Bool, root : String) : Int32 forall T
      migrator = SugarORM::Migrator.new(db, T::MIGRATIONS)
      case command
      when "migrate"
        puts "Applied #{migrator.migrate(dev_override: dev_override)} migrations."
      when "lint"
        SugarORM::Linter.enforce(migrator.lint, dev_override)
        puts "Pending migrations pass the zero-lock linter."
      when "drift"
        return drift(db)
      else
        abort("Pending migrations. Run frappe migrate first.") unless migrator.pending.empty?
        command == "seed" ? app.seed(db) : serve(app, db, url, root)
      end
      0
    end

    private def self.drift(db : DB::Database) : Int32
      difference = SugarORM::Differ.diff(SugarORM::Catalog.declared, SugarORM::Introspection.read(db))
      if difference.clean?
        puts "The database matches the declared schema."
        return 0
      end
      puts "The database differs from the declared schema:"
      print difference
      puts "  Remediation: run frappe db diff --name NAME, then frappe migrate."
      1
    end

    # Serves on the private socket `frappe dev` names, with Cold Brew's
    # workers, maintenance, schedules and PubSub; specs drain queues instead.
    private def self.serve(app : T.class, db : DB::Database, url : String, root : String) : Nil forall T
      origin = ENV["APP_ORIGIN"]? || abort("APP_ORIGIN is required")
      secret = ENV["APP_SECRET"]? || abort("APP_SECRET is required")
      socket_path = ENV["CARAMEL_SOCKET"]? || abort("CARAMEL_SOCKET is required; use frappe dev")
      parent = File.info?(File.dirname(socket_path), follow_symlinks: false)
      if parent.nil? || !parent.directory? || parent.owner_id != LibC.getuid.to_s || (parent.permissions.value & 0o077) != 0
        abort("CARAMEL_SOCKET must be in a private owned directory")
      end
      abort("Application socket is already occupied") if File.info?(socket_path, follow_symlinks: false)
      server = HTTP::Server.new([Caramel.build(app, db, secret, origin, root)])
      server.bind_unix(socket_path)
      File.chmod(socket_path, 0o600)
      cold_brew = ColdBrew.start(url) unless ENV["CARAMEL_ENV"]? == "test"
      Process.on_terminate { server.close }
      puts "#{T::TITLE} is ready at #{origin}"
      begin
        server.listen
      ensure
        server.close unless server.closed?
        File.delete?(socket_path)
        # In-flight jobs finish; no new ones start.
        cold_brew.try(&.stop)
      end
    end
  end
end
