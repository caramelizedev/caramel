require "./new_project"
require "./latte_client"
require "./installations"
require "./tools"
require "./resource_generator"
require "./dev_session"
require "./site_log"
require "./schema_diff"
require "./editor_tools"
require "./corretto_runner"
require "../caramel/database"
require "../latte/postgres"

module Caramel::Frappe
  class CLI
    COMMANDS = %w(new setup dev make migrate seed routes corretto db logs services sites installations doctor open lsp)

    def initialize(@framework_root : String, @output : IO = STDOUT, @error : IO = STDERR)
    end

    def run(arguments : Array(String)) : Int32
      args = arguments.dup
      command = args.shift? || "help"
      if {"help", "--help", "-h"}.includes?(command)
        help
        return 0
      elsif {"version", "--version", "-v"}.includes?(command)
        @output.puts("Frappé #{Caramel::VERSION}")
        return 0
      end
      unless COMMANDS.includes?(command)
        @error.puts("Unknown command: #{command}")
        nearest = COMMANDS.min_by { |known| distance(command, known) }
        @error.puts("Did you mean #{nearest}?") if distance(command, nearest) <= 3
        @error.puts("Use frappe --help for available commands.")
        return 2
      end
      if args == ["--help"] || args == ["-h"]
        @output.puts(usage(command))
        return 0
      end
      if (command == "new" && args.size != 1) || (command == "dev" && args != [] of String && args != ["--no-open"]) || (command == "migrate" && args != [] of String && args != ["--dev-override"]) || (command == "corretto" && CorrettoRunner.arguments(args).nil?) || (!{"new", "dev", "make", "migrate", "corretto", "db", "logs", "services", "sites", "installations", "lsp"}.includes?(command) && !args.empty?)
        @error.puts(usage(command))
        return 2
      end

      case command
      when "dev"
        project = Project.load
        NewProject.new(@framework_root).verify_snapshot(project)
        values = development_environment(project)
        tools = Tools.new(@framework_root, @output, @error)
        begin
          tools.check_dependencies(project)
        rescue Error
          tools.dependencies(project)
        end
        verify_origin(project)
        DevSession.new(project, tools, LatteClient.new, values, @output, @error).run(open_browser: !args.includes?("--no-open"))
      when "make"
        unless args.size >= 3 && args.shift == "resource"
          @error.puts(usage("make"))
          return 2
        end
        name = args.shift
        plural_options = args.select(&.starts_with?("--plural="))
        raise Error.new("Specify --plural only once") if plural_options.size > 1
        args.reject!(&.starts_with?("--plural="))
        plural = plural_options.first?.try(&.split('=', 2).last)
        project = Project.load
        files = ResourceGenerator.new(@framework_root).generate(project, name, args, plural: plural)
        files.each { |path| @output.puts("Generated #{path}") }
        @output.puts("\nRun frappe migrate to apply the new schema. Use frappe routes to see the generated URLs.")
      when "new"
        name = args.first
        generator = NewProject.new(@framework_root)
        generator.plan(name) # Validate the name and package before side effects.
        destination = File.join(Dir.current, name)
        if File.info?(destination, follow_symlinks: false)
          unless Dir.exists?(destination) && !File.symlink?(destination) && Dir.children(destination).empty?
            raise Error.new("Project destination must be empty; existing files were preserved")
          end
        end
        tools = Tools.new(@framework_root, @output, @error)
        client = LatteClient.new
        client.ready!
        project = generator.create(name, destination)
        @output.puts("Created #{project.name}. Installing locked dependencies…")
        begin
          tools.dependencies(project)
          configure(project, client)
        rescue ex : Error
          raise Error.new("#{ex.message}\nProject files were preserved. Run cd #{name} && frappe setup to resume.")
        end
        @output.puts("\n#{project.name} is configured at #{project.origin}\n\nNext:\n  cd #{name}\n  frappe dev")
      when "setup"
        project = Project.load
        NewProject.new(@framework_root).verify_snapshot(project)
        tools = Tools.new(@framework_root, @output, @error)
        client = LatteClient.new
        client.ready!
        tools.dependencies(project)
        configure(project, client)
        @output.puts("#{project.name} is configured. Run frappe dev.")
      when "migrate", "seed", "routes"
        project = Project.load
        values = command == "routes" ? {} of String => String : development_environment(project)
        values["CARAMEL_ENV"] = "development"
        if command != "routes"
          values["CARAMEL_EXPECTED_DATABASE_URL"] = values[command == "migrate" ? "MIGRATION_DATABASE_URL" : "DATABASE_URL"]
        end
        tools = Tools.new(@framework_root, @output, @error)
        if command == "migrate"
          migrate(project, tools, values, args)
        else
          tools.app_command(project, [command], values)
        end
      when "corretto"
        paths, concurrency = CorrettoRunner.arguments(args).not_nil!
        CorrettoRunner.new(@framework_root, Project.load, @output, @error).run(paths, concurrency)
      when "db"
        return db(args)
      when "services"
        return services(args)
      when "sites"
        return sites(args)
      when "installations"
        return installations(args)
      when "logs"
        return logs(args)
      when "doctor"
        return doctor
      when "lsp"
        return lsp(args)
      when "open"
        project = Project.load
        verify_origin(project)
        result = Process.run("/usr/bin/open", [project.origin])
        raise Error.new("Could not open the project URL") unless result.success?
      end
      0
    rescue ex : Error
      @error.puts(ex.message)
      1
    rescue ex : File::Error
      @error.puts("A required project or installation file is unavailable. Run frappe doctor.")
      1
    rescue ex
      @error.puts("Frappé could not complete this command (#{ex.class}). Run frappe doctor.")
      1
    end

    # Lints and applies pending migrations, then reports schema drift through
    # the application's read-only runtime connection as a warning.
    private def migrate(project : Project, tools : Tools, values : Hash(String, String), flags : Array(String)) : Nil
      binary = tools.compile(project)
      tools.run(binary, ["migrate"] + flags, project.root, values)
      status, report = tools.capture(binary, ["drift"], project.root, values.merge({"CARAMEL_EXPECTED_DATABASE_URL" => values["DATABASE_URL"]}))
      if status.success?
        @output.print(report)
      else
        @error.puts("WARNING: schema drift (read-only check; nothing was changed):")
        @error.print(report)
      end
    end

    private def configure(project : Project, client : LatteClient) : Nil
      site = client.register(project)
      values = client.environment(site["id"].as_s, project.root)
      project.ensure_local_environment(values)
    end

    private def development_environment(project : Project) : Hash(String, String)
      client = LatteClient.new
      client.ready!
      id = Latte::Site.id_for(project.name, project.root, project.metadata.domain_suffix)
      authoritative = client.environment(id, project.root)
      values = project.local_environment
      %w(DATABASE_URL MIGRATION_DATABASE_URL).each do |key|
        raise Error.new("#{key} differs from this project's Latte credentials; command refused") unless values[key]? == authoritative[key]?
      end
      raise Error.new("APP_ORIGIN differs from this project; run frappe setup") unless values["APP_ORIGIN"]? == project.origin
      values
    end

    private def lsp(args : Array(String)) : Int32
      action = args.shift?
      if action == "install" && args.empty?
        tools = Tools.new(@framework_root, @output, @error)
        EditorTools.new(@framework_root, @output, @error).install(tools)
      elsif action && EditorTools::SERVERS.includes?(action)
        directory = File.realpath(Dir.current)
        # Outside the framework checkout, the project must match this installation.
        Project.load unless directory == File.realpath(@framework_root)
        EditorTools.new(@framework_root, @output, @error).exec(action, args, directory)
      else
        @error.puts(usage("lsp"))
        return 2
      end
      0
    end

    private def services(args : Array(String)) : Int32
      client = LatteClient.new
      case args
      when [] of String, ["status"]
      when ["start"]
        client.ready!
      when ["stop"]
        client.stop_services
      else
        @error.puts(usage("services"))
        return 2
      end
      document = client.status
      document["services"].as_h.each { |name, value| @output.puts("#{name.ljust(12)} #{value["state"].as_s}") }
      if message = document["error"]?.try(&.as_s?)
        @error.puts(message)
        return 1
      end
      0
    end

    private def doctor : Int32
      failures = 0
      checks = {
        "Project configuration"       => -> { Project.load; nil },
        "Framework snapshot"          => -> { NewProject.new(@framework_root).verify_snapshot(Project.load) },
        "Managed Crystal compiler"    => -> { Tools.new(@framework_root).check_compiler },
        "Locked dependencies"         => -> { Tools.new(@framework_root).check_dependencies(Project.load) },
        "Managed PostgreSQL tool"     => -> { Tools.new(@framework_root).toolchain.verify_postgres_version!; nil },
        "Private local configuration" => -> { Project.load.local_environment; nil },
        "Latte services"              => -> { document = LatteClient.new.status; raise Error.new("Latte services are not all running") unless document["services"].as_h.values.all? { |item| item["state"].as_s == "running" }; nil },
        "Named, trusted HTTPS"        => -> { verify_origin(Project.load) },
      }
      checks.each do |label, check|
        begin
          check.call
          @output.puts("OK    #{label}")
        rescue ex
          failures += 1
          @output.puts("CHECK #{label}: #{ex.is_a?(Error) ? ex.message : ex.class.to_s}")
        end
      end
      failures == 0 ? 0 : 1
    end

    private def verify_origin(project : Project) : Nil
      result = Latte::ProcessRunner.run(["/usr/bin/curl", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*", "--output", "/dev/null", "--write-out", "%{remote_ip}", project.origin + "/health"], timeout: 7.seconds, output_limit: 4096)
      unless result.success? && result.stdout == "127.0.0.1"
        raise Error.new("#{project.origin} must resolve to loopback with trusted HTTPS; check Latte DNS, port integration and certificate trust")
      end
    end

    private def sites(args : Array(String)) : Int32
      if args.empty?
        LatteClient.new.sites.each do |site|
          state = site["state"]?.try(&.as_s?) || "unknown"
          state = "unknown" unless %w(running building build-error stopped unavailable unknown).includes?(state)
          owner = site["owner"]?.try(&.as_s?) == "terminal" ? " (terminal)" : ""
          @output.puts("#{site["name"].as_s.ljust(24)} #{(state + owner).ljust(24)} #{site["origin"].as_s}  #{site["directory"].as_s}")
        end
      elsif args.size == 2 && args[0] == "remove"
        name = args[1]
        client = LatteClient.new
        client.ready!
        entry = client.sites.find { |site| site["name"].as_s == name }
        raise Error.new("No registered site is named #{name}") unless entry
        id = entry["id"].as_s
        client.with_site_lock(id, name) { client.unregister(id) }
        @output.puts("Removed #{name} (#{entry["origin"].as_s}) from Latte. Its project folder, databases, credentials, logs and backups were kept. Run frappe setup in #{entry["directory"].as_s} to register it again.")
      else
        @error.puts(usage("sites"))
        return 2
      end
      0
    end

    private def db(args : Array(String)) : Int32
      return schema_diff(args[1..]) if args.first? == "diff"
      unless args == ["dump"] || (args.size == 2 && args[0] == "restore")
        @error.puts(usage("db"))
        return 2
      end
      project = Project.load
      client = LatteClient.new
      client.ready!
      site = Latte::Site.new(project.name, project.root, project.metadata.domain_suffix)
      paths = Latte::Paths.new(client.root)
      postgres = Latte::Postgres.new(paths, Tools.new(@framework_root, @output, @error).toolchain)
      backups = Latte::StateSecurity.ensure_owned_directory(File.join(paths.root, "backups", site.id))
      dump_to = ->(prefix : String) {
        postgres.backup(site, File.join(backups, "#{Time.utc.to_s("%Y%m%dT%H%M%S.%LZ")}-#{prefix}.dump"))
      }
      if args[0] == "dump"
        @output.puts("Saved #{project.name} development database: #{dump_to.call("development")}")
      else
        file = File.expand_path(args[1])
        client.with_site_lock(site.id, project.name) do
          safety = dump_to.call("pre-restore")
          postgres.restore(site, file)
          @output.puts("Saved the current development database to #{safety}")
          @output.puts("Restored #{project.name} development database from #{file}")
        end
      end
      0
    rescue ex : Latte::Postgres::SecretMissing
      raise Error.new("frappe db: #{project.not_nil!.name} has no provisioned database; run frappe setup first")
    rescue ex : Latte::Postgres::Error | Latte::OwnershipError | ArgumentError
      raise Error.new("frappe db: #{ex.message}")
    end

    private def schema_diff(args : Array(String)) : Int32
      dev_override = !args.delete("--dev-override").nil?
      unless args.size == 2 && args[0] == "--name"
        @error.puts(usage("db"))
        return 2
      end
      project = Project.load
      tools = Tools.new(@framework_root, @output, @error)
      client = LatteClient.new
      client.ready!
      SchemaDiff.new(project, tools, client, @output, @error).run(args[1], dev_override)
      0
    end

    private def logs(args : Array(String)) : Int32
      follow = !!args.delete("--follow")
      kind = args.shift? || "app"
      unless %w(app compiler).includes?(kind) && args.empty?
        @error.puts(usage("logs"))
        return 2
      end
      project = Project.load
      id = Latte::Site.id_for(project.name, project.root, project.metadata.domain_suffix)
      directory = LatteClient.new.site_log_directory(id, create: false)
      path = directory ? File.join(directory, "#{kind}.log") : nil
      unless path && File.info?(path, follow_symlinks: false)
        raise Error.new("No #{kind} log for #{project.name} yet. Run frappe dev.")
      end
      SiteLog.validate_file(path)
      Process.run("/usr/bin/tail", ["-n", "200", *(follow ? ["-F"] : [] of String), path], output: @output, error: @error).exit_code
    end

    private def installations(args : Array(String)) : Int32
      registry = Installations.new
      case args
      when [] of String, ["list"]
        entries = registry.list
        if entries.empty?
          @output.puts("No Caramel installations are registered. Run frappe installations register from a Caramel checkout.")
        else
          current = File.realpath(@framework_root)
          entries.keys.sort.each do |release|
            root = entries[release]
            @output.puts("#{release.ljust(12)} #{root}#{root == current ? "  (this installation)" : ""}")
          end
        end
      when ["register"]
        root = File.realpath(@framework_root)
        binary = File.join(root, "bin/frappe")
        info = File.info?(binary, follow_symlinks: false)
        unless info && info.file? && File::Info.executable?(binary)
          raise Error.new("#{binary} is missing; run scripts/build-frappe first")
        end
        previous = registry.register(Caramel::VERSION, root)
        @output.puts("Registered Caramel #{Caramel::VERSION}: #{root}#{previous && previous != root ? " (replaced #{previous})" : ""}")
      else
        if args.size == 2 && args[0] == "remove"
          release = args[1]
          raise Error.new("Caramel #{release} is not registered") unless registry.remove(release)
          @output.puts("Removed Caramel #{release} from the installation registry.")
        else
          @error.puts(usage("installations"))
          return 2
        end
      end
      0
    end

    private def help : Nil
      @output.puts("Frappé — Caramel's application CLI\n")
      COMMANDS.each { |command| @output.puts("  #{usage(command)}") }
      @output.puts("\nUse frappe COMMAND --help for command syntax.")
    end

    private def usage(command : String) : String
      case command
      when "dev"      then "frappe dev [--no-open]"
      when "make"     then "frappe make resource NAME FIELD:TYPE... [--plural=NAME]"
      when "new"      then "frappe new NAME"
      when "corretto" then "frappe corretto [SPEC_PATHS...] [--concurrency=1..#{CorrettoRunner::MAX_CONCURRENCY}]"
      when "db"       then "frappe db dump | frappe db restore FILE | frappe db diff --name NAME [--dev-override]"
      when "migrate"  then "frappe migrate [--dev-override]"
      when "sites"    then "frappe sites [remove NAME]"
      when "installations" then "frappe installations [list|register|remove VERSION]"
      when "logs"     then "frappe logs [app|compiler] [--follow]"
      when "services" then "frappe services [status|start|stop]"
      when "lsp"      then "frappe lsp crystalline|ameba-ls [SERVER_ARGS] | frappe lsp install"
      else                 "frappe #{command}"
      end
    end

    private def distance(left : String, right : String) : Int32
      previous = (0..right.size).to_a
      left.each_char.with_index(1) do |a, row|
        current = [row]
        right.each_char.with_index(1) do |b, column|
          current << {current[column - 1] + 1, previous[column] + 1, previous[column - 1] + (a == b ? 0 : 1)}.min
        end
        previous = current
      end
      previous.last
    end
  end
end
