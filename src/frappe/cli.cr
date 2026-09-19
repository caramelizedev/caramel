require "./new_project"
require "./latte_client"
require "./tools"
require "./resource_generator"
require "./dev_session"
require "../caramel/database"
require "../latte/postgres"

module Caramel::Frappe
  class CLI
    COMMANDS = %w(new setup dev make migrate seed routes test services sites doctor open)

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
      if (command == "new" && args.size != 1) || (command == "dev" && args != [] of String && args != ["--no-open"]) || (!{"new", "dev", "make", "test", "services"}.includes?(command) && !args.empty?)
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
        Tools.new(@framework_root, @output, @error).app_command(project, [command], values)
      when "test"
        test(Project.load, args)
      when "services"
        return services(args)
      when "sites"
        LatteClient.new.sites.each do |site|
          state = site["state"]?.try(&.as_s?) || "unknown"
          state = "unknown" unless %w(running building build-error stopped unavailable unknown).includes?(state)
          owner = site["owner"]?.try(&.as_s?) == "terminal" ? " (terminal)" : ""
          @output.puts("#{site["name"].as_s.ljust(24)} #{(state + owner).ljust(24)} #{site["origin"].as_s}  #{site["directory"].as_s}")
        end
      when "doctor"
        return doctor
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

    private def test(project : Project, args : Array(String)) : Nil
      NewProject.new(@framework_root).verify_snapshot(project)
      client = LatteClient.new
      client.ready!
      id = Latte::Site.id_for(project.name, project.root, project.metadata.domain_suffix)
      authoritative = client.environment(id, project.root)
      local = project.local_environment
      %w(SPEC_DATABASE_URL SPEC_MIGRATION_DATABASE_URL).each do |key|
        raise Error.new("#{key} differs from this project's Latte credentials; test refused") unless local[key]? == authoritative[key]?
      end
      config = Caramel::Database::Config.parse(authoritative["SPEC_DATABASE_URL"])
      migration_config = Caramel::Database::Config.parse(authoritative["SPEC_MIGRATION_DATABASE_URL"])
      development = Caramel::Database::Config.parse(authoritative["DATABASE_URL"])
      expected_spec = Latte::Postgres.database_names(id).spec
      unless config.database == expected_spec && config.database != development.database && migration_config.database == config.database && migration_config.host == config.host && migration_config.port == config.port
        raise Error.new("Spec database identity is not isolated from development; test refused")
      end
      db = Caramel::Database.open(authoritative["SPEC_DATABASE_URL"])
      begin
        unless db.query_one("SELECT current_database()", as: String) == config.database && db.query_one("SELECT current_user", as: String) == config.user
          raise Error.new("Connected spec database identity differs; test refused")
        end
      ensure
        db.close
      end
      values = {
        "CARAMEL_ENV" => "test", "CARAMEL_SPEC_DATABASE" => config.database,
        "APP_ORIGIN" => project.origin, "APP_SECRET" => Random::Secure.hex(32),
        "DATABASE_URL" => authoritative["SPEC_DATABASE_URL"],
        "MIGRATION_DATABASE_URL" => authoritative["SPEC_MIGRATION_DATABASE_URL"],
        "SPEC_DATABASE_URL" => authoritative["SPEC_DATABASE_URL"],
        "SPEC_MIGRATION_DATABASE_URL" => authoritative["SPEC_MIGRATION_DATABASE_URL"],
        "CARAMEL_EXPECTED_DATABASE_URL" => authoritative["SPEC_MIGRATION_DATABASE_URL"],
      }
      tools = Tools.new(@framework_root, @output, @error)
      tools.app_command(project, ["migrate"], values)
      values["CARAMEL_EXPECTED_DATABASE_URL"] = authoritative["SPEC_DATABASE_URL"]
      tools.specs(project, args, values)
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
      when "test"     then "frappe test [SPEC_OPTIONS]"
      when "services" then "frappe services [status|start|stop]"
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
