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
  def self.run(app : T.class,
               arguments : Array(String) = ARGV,
               source : String = __DIR__) : NoReturn forall T
    exit CommandLine.run(app, arguments, File.expand_path("..", source))
  end

  # The application's HTTP handler on a database pool: its router behind
  # CSRF protection, serving *root*/public.
  def self.build(app : T.class,
                 db : DB::Database,
                 secret : String,
                 origin : String,
                 root : String) : Application forall T
    SugarORM::Repo.database = db
    Application.new(T::AppRouter.new, CSRF.new(secret, origin), File.join(root, "public"))
  end

  module CommandLine
    USAGE = [
      "serve",
      "work [--queues=NAMES] [--concurrency=N] [--no-scheduler]",
      "seed", "routes", "schema", "drift", "translations",
      "migrate [--dev-override]",
      "lint [--dev-override]",
    ].join('|')

    # `work`'s flags: `--queues` and `--concurrency` stand in for
    # CARAMEL_WORKER_QUEUES and CARAMEL_WORKER_CONCURRENCY, which
    # `ColdBrew.start` validates, and `--no-scheduler` leaves `every`
    # schedules to other processes.
    record WorkOptions,
      queues : String? = nil,
      concurrency : String? = nil,
      scheduler : Bool = true

    # Reopened rather than given as `record`'s block: `crystal tool expand`
    # cannot re-read a `protected def` inside that block.
    struct WorkOptions
      # Nil for an unknown or repeated flag, or a flag missing its value.
      def self.parse(arguments : Array(String)) : WorkOptions?
        names = arguments.map(&.partition('=')[0])
        return unless names.uniq.size == names.size

        arguments.reduce(new) { |options, argument| options.adding(argument) || return }
      end

      # These options with one more flag; nil when the flag is not `work`'s.
      protected def adding(argument : String) : WorkOptions?
        name, equals, value = argument.partition('=')
        case name
        when "--queues"       then copy_with(queues: value) unless value.empty?
        when "--concurrency"  then copy_with(concurrency: value) unless value.empty?
        when "--no-scheduler" then copy_with(scheduler: false) if equals.empty?
        end
      end

      # *env* with the flags' worker settings applied.
      def environment(env : Hash(String, String) = ENV.to_h) : Hash(String, String)
        values = env.dup
        queues.try { |names| values["CARAMEL_WORKER_QUEUES"] = names }
        concurrency.try { |count| values["CARAMEL_WORKER_CONCURRENCY"] = count }
        values
      end
    end

    # Runs one command and returns its exit status. `App` provides TITLE,
    # MIGRATIONS, AppRouter and `seed`.
    def self.run(app : T.class, arguments : Array(String), root : String) : Int32 forall T
      command = arguments.first? || "help"
      flags = arguments[1..]? || [] of String
      if command == "work"
        options = WorkOptions.parse(flags) || return refuse_usage
        return run_workers(app, options)
      end
      dev_override = flags == ["--dev-override"] && {"migrate", "lint"}.includes?(command)
      return refuse_usage unless flags.empty? || dev_override

      case command
      when "routes", "schema", "translations"
        describe(app, command, root)
      when "serve", "seed", "migrate", "lint", "drift"
        with_database(command == "migrate") do |db, url|
          database_command(app, command, db, url, dev_override, root)
        end
      else
        puts usage
        command == "help" ? 0 : 2
      end
    end

    # Answers from the compiled application alone, without a database: its
    # routes, its declared schema or the keys its locales lack.
    private def self.describe(app : T.class, command : String, root : String) : Int32 forall T
      case command
      when "routes" then routes(T::AppRouter.routes)
      when "schema" then schema
      else               translations(root)
      end
    end

    private def self.schema : Int32
      puts SugarORM::Catalog.to_json(SugarORM::Catalog.declared)
      0
    end

    # Runs Cold Brew's workers, maintenance and, unless disabled, schedules
    # without an HTTP server until *stop* closes, then lets in-flight jobs
    # finish. The ready line goes to *output* once the workers are claiming.
    def self.work(title : String, url : String, options : WorkOptions,
                  stop : Channel(Nil), output : IO = STDOUT) : Int32
      service = ColdBrew.start(url, options.environment, scheduler: options.scheduler)
      begin
        output.puts "#{title} worker is ready: #{readiness(service, options)}"
        output.flush
        stop.receive?
      ensure
        # In-flight jobs finish; no new ones start.
        service.stop
      end
      0
    end

    # Lists the keys each locale takes from the default one, and returns 1
    # while any is missing. `caramel/i18n` replaces it.
    def self.translations(root : String) : Int32
      puts "This application declares no locales."
      0
    end

    private def self.usage : String
      "Usage: #{File.basename(PROGRAM_NAME)} #{USAGE}"
    end

    private def self.refuse_usage : Int32
      STDERR.puts(usage)
      2
    end

    # `work`, once the database holds every migration; a signal stops it.
    private def self.run_workers(app : T.class, options : WorkOptions) : Int32 forall T
      if ENV["CARAMEL_ENV"]? == "test"
        abort("Specs run no workers; drain queues with Caramel::ColdBrew.drain_queue!")
      end
      with_database(false) do |db, url|
        refuse_pending(db, T::MIGRATIONS)
        stop = Channel(Nil).new
        # A second signal finds the channel closed and changes nothing.
        Process.on_terminate { stop.close }
        work(T::TITLE, url, options, stop)
      end
    end

    # Such as `queues default, mailers; concurrency 4; scheduler on`.
    private def self.readiness(service : ColdBrew::Service,
                               options : WorkOptions) : String
      queues = service.workers.join(", ", &.queue)
      concurrency = service.workers.first?.try(&.concurrency) || 0
      scheduler = options.scheduler ? "on" : "off"
      "queues #{queues}; concurrency #{concurrency}; scheduler #{scheduler}"
    end

    private def self.routes(entries : Array(Router::Entry)) : Int32
      width = entries.max_of? { |entry| listed_path(entry).size } || 0
      entries.each do |entry|
        line = "#{entry.method.ljust(7)} #{listed_path(entry).ljust(width)}  #{entry.action}"
        line += "  #{entry.contract}" unless entry.contract.empty?
        ingress = entry.ingress.summary
        line += "  [#{ingress}]" unless ingress.empty?
        puts line
      end
      0
    end

    # A route's path as listed: a tenant route under `/:tenant`.
    private def self.listed_path(entry : Router::Entry) : String
      return entry.path unless entry.tenant
      entry.path == "/" ? "/:tenant" : "/:tenant#{entry.path}"
    end

    # Opens the environment's database, refusing a connection other than the
    # one Frappé verified and any spec database outside Corretto.
    private def self.with_database(migration : Bool, & : DB::Database, String -> Int32) : Int32
      url = Database.url(migration: migration)
      if expected = ENV["CARAMEL_EXPECTED_DATABASE_URL"]?
        unless url == expected
          abort("Database connection differs from the verified launcher configuration")
        end
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
      rescue ex : SugarORM::Migrator::Drift | SugarORM::Migrator::ConcurrentIndexFailed
        STDERR.puts(ex.message)
        1
      rescue ex : ColdBrew::ConfigurationError
        STDERR.puts(ex.message)
        1
      ensure
        db.close
      end
    end

    private def self.database_command(app : T.class,
                                      command : String,
                                      db : DB::Database,
                                      url : String,
                                      dev_override : Bool,
                                      root : String) : Int32 forall T
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
        refuse_pending(db, T::MIGRATIONS)
        command == "seed" ? app.seed(db) : serve(app, db, url, root)
      end
      0
    end

    private def self.refuse_pending(db : DB::Database,
                                    migrations : Array(SugarORM::Migration)) : Nil
      return if SugarORM::Migrator.new(db, migrations).pending.empty?

      abort("Pending migrations. Run frappe migrate first.")
    end

    private def self.drift(db : DB::Database) : Int32
      declared = SugarORM::Catalog.declared
      difference = SugarORM::Differ.diff(declared, SugarORM::Introspection.read(db))
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
    private def self.serve(app : T.class,
                           db : DB::Database,
                           url : String,
                           root : String) : Nil forall T
      origin = ENV["APP_ORIGIN"]? || abort("APP_ORIGIN is required")
      secret = ENV["APP_SECRET"]? || abort("APP_SECRET is required")
      socket_path = ENV["CARAMEL_SOCKET"]? || abort("CARAMEL_SOCKET is required; use frappe dev")
      parent = File.info?(File.dirname(socket_path), follow_symlinks: false)
      abort("CARAMEL_SOCKET must be in a private owned directory") if exposed?(parent)
      occupied = File.info?(socket_path, follow_symlinks: false)
      abort("Application socket is already occupied") if occupied
      server = HTTP::Server.new([Caramel.build(app, db, secret, origin, root)])
      # ameba:disable Lint/UselessAssign -- read by the ensure below when binding fails
      bound = false
      cold_brew : ColdBrew::Service? = nil
      begin
        server.bind_unix(socket_path)
        bound = true
        File.chmod(socket_path, 0o600)
        # Invalid worker settings raise here; the ensure still frees the socket.
        cold_brew = ColdBrew.start(url) unless ENV["CARAMEL_ENV"]? == "test"
        Process.on_terminate { server.close }
        puts "#{T::TITLE} is ready at #{origin}"
        server.listen
      ensure
        server.close unless server.closed?
        File.delete?(socket_path) if bound
        # In-flight jobs finish; no new ones start.
        cold_brew.try(&.stop)
      end
    end

    # True unless *info* is a directory that the current user owns and that
    # no one else can reach.
    private def self.exposed?(info : File::Info?) : Bool
      return true if info.nil? || !info.directory?
      info.owner_id != LibC.getuid.to_s || (info.permissions.value & 0o077) != 0
    end
  end
end
