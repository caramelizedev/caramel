require "./commands"
require "./mrdp"
require "./check"
require "./lint"
require "./new_project"
require "./latte_client"
require "./installations"
require "./release"
require "./launchers"
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
    def initialize(@framework_root : String, @output : IO = STDOUT, @error : IO = STDERR)
    end

    def run(arguments : Array(String)) : Int32
      args = arguments.empty? ? ["help"] : arguments.dup
      args[0] = "help" if {"--help", "-h"}.includes?(args[0])
      args[0] = "version" if {"--version", "-v"}.includes?(args[0])
      if args.size > 1 && {"--help", "-h"}.includes?(args.last) && !(matches = Commands.matching(args[0...-1])).empty?
        matches.each { |command| @output.puts("Usage: frappe #{command.syntax}\n  #{command.summary}") }
        return 0
      end
      invocation = Commands.parse(args)
      invocation.command.deprecated.try do |replacement|
        @error.puts("Warning: frappe #{invocation.command.name} is deprecated and will be removed in the next minor release. #{replacement}")
      end
      execute(invocation)
    rescue ex : Commands::Usage
      usage(ex, arguments)
      1
    rescue ex : Error
      @error.puts(ex.message)
      1
    rescue File::Error
      @error.puts("A required project or installation file is unavailable. Run frappe doctor.")
      1
    rescue ex
      @error.puts("Frappé could not complete this command (#{ex.class}). Run frappe doctor.")
      1
    end

    # Keeps the routes whose method, path or action contains `filter`,
    # ignoring case; contract summaries are not searched.
    def self.filter_routes(listing : String, filter : String) : String
      needle = filter.downcase
      String.build do |io|
        listing.each_line(chomp: false) do |line|
          io << line if line.split[0, 3].any?(&.downcase.includes?(needle))
        end
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity -- one branch per command
    private def execute(invocation : Commands::Invocation) : Int32
      case name = invocation.command.name
      when "help"
        help
      when "version"
        @output.puts("Frappé #{Caramel::VERSION}")
      when "agent-manifest"
        manifest
      when "new"
        create(invocation["NAME"])
      when "setup"
        project = Project.load
        tools = Tools.new(@framework_root, @output, @error)
        client = LatteClient.new
        client.ready!
        tools.dependencies(project)
        configure(project, client)
        migrate_configured(project, tools)
        @output.puts("#{project.name} is configured. Run frappe dev.")
      when "dev"
        dev(invocation)
      when "check"
        agent = MRDP.agent?(invocation.flags, @output)
        return Check.new(Project.load, Tools.new(@framework_root, @output, @error), @output).run(agent, !agent && @output.tty?)
      when "lint"
        agent = MRDP.agent?(invocation.flags, @output)
        return Lint.new(Project.load, Tools.new(@framework_root, @output, @error), @output, @error).run(agent, !agent && @output.tty?)
      when "format"
        project = Project.load
        directories = %w[src config app db spec].select { |directory| Dir.exists?(File.join(project.root, directory)) }
        Tools.new(@framework_root, @output, @error).run(File.join(@framework_root, "scripts/crystal"), ["tool", "format"] + directories, project.root)
      when "routes"
        routes(invocation["FILTER"]?)
      when "expand"
        return expand(invocation["FILE:LINE:COL"])
      when "make resource"
        project = Project.load
        files = ResourceGenerator.new(@framework_root).generate(project, invocation["NAME"], invocation.list("FIELD:TYPE"), plural: invocation["--plural"]?, only: invocation["--only"]?)
        files.each { |path| @output.puts("Generated #{path}") }
        @output.puts("\nRun frappe migrate to apply the new schema. Use frappe routes to see the generated URLs.")
      when "migrate"
        return migrate(invocation)
      when "seed"
        project = Project.load
        values = development_environment(project).merge({"CARAMEL_ENV" => "development"})
        values["CARAMEL_EXPECTED_DATABASE_URL"] = values["DATABASE_URL"]
        Tools.new(@framework_root, @output, @error).app_command(project, ["seed"], values)
      when "corretto"
        paths = invocation.list("SPEC_PATHS")
        concurrency = invocation["--concurrency"]?.try(&.to_i) || 1
        CorrettoRunner.new(@framework_root, Project.load, @output, @error).run(paths.empty? ? ["spec"] : paths, concurrency)
      when "db dump", "db restore"
        backup(invocation["FILE"]?)
      when "db diff"
        project = Project.load
        tools = Tools.new(@framework_root, @output, @error)
        client = LatteClient.new
        client.ready!
        SchemaDiff.new(project, tools, client, @output, @error).run(invocation["--name"], invocation.flag?("--dev-override"), MRDP.agent?(invocation.flags, @output))
      when "db branch create", "db branch list", "db branch delete"
        branch(invocation)
      when "logs"
        return logs(invocation["app|compiler"]? || "app", invocation.flag?("--follow"))
      when "services"
        return services(invocation["status|start|stop"]? || "status")
      when "sites"
        sites
      when "sites remove"
        remove_site(invocation["NAME"])
      when "installations", "installations install", "installations register", "installations remove"
        installations(invocation)
      when "doctor"
        return doctor
      when "open"
        project = Project.load
        verify_origin(project)
        result = Process.run("/usr/bin/open", [project.origin])
        raise Error.new("Could not open the project URL") unless result.success?
      when "lsp"
        directory = File.realpath(Dir.current)
        # Outside the framework checkout, the project must match this installation.
        Project.load unless directory == File.realpath(@framework_root)
        EditorTools.new(@framework_root, @output, @error).exec(invocation["crystalline|ameba-ls"], invocation.list("SERVER_ARGS"), directory)
      when "lsp install"
        EditorTools.new(@framework_root, @output, @error).install(Tools.new(@framework_root, @output, @error))
      else
        raise Error.new("Frappé has no handler for frappe #{name}")
      end
      0
    end

    private def usage(error : Commands::Usage, arguments : Array(String)) : Nil
      syntax = error.syntax
      if MRDP.agent?(arguments, @output)
        fields = [{"MSG", error.message.to_s}]
        fields << {"SYNTAX", syntax} if syntax
        fields << {"SUGGEST", error.suggestion.to_s} if error.suggestion
        fields << {"FIX", "frappe agent-manifest lists every command"} unless syntax
        MRDP.write(@error, "USAGE", error.subject, fields)
      else
        @error.puts("#{error.subject}: #{error.message}")
        @error.puts("Usage: #{syntax}") if syntax
        error.suggestion.try { |suggestion| @error.puts("Did you mean #{suggestion}?") }
        @error.puts("Use frappe --help for available commands.") unless syntax
      end
    end

    private def help : Nil
      @output.puts("Frappé — Caramel's application CLI\n")
      Commands::TABLE.each { |command| @output.puts("  frappe #{command.syntax}\n      #{command.summary}") }
      @output.puts("\nUse frappe COMMAND --help for one command's syntax. Diagnostics print as MRDP with --agent or when stdout is not a terminal; --human selects the terminal layout.")
    end

    # Stateless: reads only the command table (RFC-0005 §2.1).
    private def manifest : Nil
      @output.puts("CARAMEL CLI INTERFACE (STRICT TOKENS)")
      @output.puts("VERSION: #{Caramel::VERSION}")
      @output.puts("DOCS: #{Caramel::REPOSITORY}/tree/v#{Caramel::VERSION}")
      Commands::TABLE.each { |command| @output.puts("frappe #{command.syntax}  # #{command.summary}") }
      @output.puts
      @output.puts(MRDP::GRAMMAR)
    end

    private def create(name : String) : Nil
      generator = NewProject.new(@framework_root)
      generator.plan(name) # Validate the name and package before side effects.
      destination = File.join(Dir.current, name)
      if File.info?(destination, follow_symlinks: false)
        if !Dir.exists?(destination) || File.symlink?(destination) || !Dir.children(destination).empty?
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
        migrate_configured(project, tools)
      rescue ex : Error
        raise Error.new("#{ex.message}\nProject files were preserved. Run cd #{name} && frappe setup to resume.")
      end
      @output.puts("\n#{project.name} is configured at #{project.origin}\n\nNext:\n  cd #{name}\n  frappe dev")
    end

    private def dev(invocation : Commands::Invocation) : Nil
      requested = invocation["--branch"]?.try { |name| branch_name!(invocation, name) }
      project = Project.load
      values = development_environment(project)
      client = LatteClient.new
      runtime_url = requested.try do |name|
        id = Latte::Site.id_for(project.name, project.root, project.metadata.domain_suffix)
        unless client.branches(id).any? { |entry| entry["name"].as_s? == name }
          raise Error.new("#{project.name} has no database branch #{name}; create it with frappe db branch create #{name}")
        end
        LatteClient.branch_url(values["DATABASE_URL"], Latte::Postgres.branch_database(id, name))
      end
      tools = Tools.new(@framework_root, @output, @error)
      begin
        tools.check_dependencies(project)
      rescue Error
        tools.dependencies(project)
      end
      verify_origin(project)
      DevSession.new(project, tools, client, values, @output, @error, runtime_url: runtime_url).run(open_browser: !invocation.flag?("--no-open"))
    end

    private def routes(filter : String?) : Nil
      project = Project.load
      tools = Tools.new(@framework_root, @output, @error)
      status, listing = tools.capture(tools.compile(project), ["routes"], project.root, {"CARAMEL_ENV" => "development"})
      raise Error.new("The application's routes command failed; see the diagnostic above") unless status.success?
      listing = CLI.filter_routes(listing, filter) if filter
      @output.print(listing)
      @error.puts("No route's method, path or action contains #{filter}.") if filter && listing.empty?
    end

    # `crystal tool expand` sees macro calls in method bodies and in the files
    # given as sources, not the top level of required files. FILE and every
    # file required after it are therefore passed as sources, in the order the
    # main target requires them, so macros that depend on FILE still follow it.
    private def expand(location : String) : Int32
      match = location.match(/\A(.+):([1-9][0-9]*):([1-9][0-9]*)\z/)
      raise Commands::Usage.new("#{location} is not FILE:LINE:COL", "frappe expand", Commands.matching(["expand"])) unless match
      project = Project.load
      path = File.expand_path(match[1], project.root)
      raise Error.new("No file #{match[1]} in #{project.name}") unless File.file?(path)
      tools = Tools.new(@framework_root, @output, @error)
      compiler = File.join(@framework_root, "scripts/crystal")
      status, listing = tools.capture(compiler, ["tool", "dependencies", "-f", "flat", *Check::DEFINES, project.entrypoint], project.root)
      raise Error.new("Could not list the application's source files; see the diagnostic above") unless status.success?
      files = listing.lines.map(&.strip)
      following = files.index(Path[path].relative_to(project.root).to_s).try { |index| files[index..] } || [] of String
      arguments = ["tool", "expand", *Check::DEFINES, "-c", "#{path}:#{match[2]}:#{match[3]}", project.entrypoint, *following]
      status, expansion = tools.capture(compiler, arguments, project.root)
      @output.print(expansion)
      status.success? && !expansion.starts_with?("no expansion found") ? 0 : 1
    end

    # Lints and applies pending migrations, then reports schema drift through
    # the application's read-only runtime connection as a warning. In agent
    # mode the application prints lint violations as MRDP.
    private def migrate(invocation : Commands::Invocation) : Int32
      project = Project.load
      values = development_environment(project).merge({"CARAMEL_ENV" => "development"})
      agent = MRDP.agent?(invocation.flags, @output)
      tools = Tools.new(@framework_root, @output, @error)
      binary = tools.compile(project)
      flags = invocation.flag?("--dev-override") ? ["--dev-override"] : [] of String
      status = apply_migrations(project, tools, binary, values, flags, agent)
      unless status.success?
        return 1 if agent
        raise Error.new("Command failed (exit #{status.exit_code}); see the diagnostic above")
      end
      status, report = tools.capture(binary, ["drift"], project.root, values.merge({"CARAMEL_EXPECTED_DATABASE_URL" => values["DATABASE_URL"]}))
      if status.success?
        @output.print(report)
      else
        @error.puts("WARNING: schema drift (read-only check; nothing was changed):")
        @error.print(report)
      end
      0
    end

    # Lints and applies pending migrations through the migration role.
    private def apply_migrations(project : Project, tools : Tools, binary : String, values : Hash(String, String),
                                 flags : Array(String) = [] of String, agent : Bool = false) : Process::Status
      settings = values.merge({"CARAMEL_EXPECTED_DATABASE_URL" => values["MIGRATION_DATABASE_URL"]})
      settings["CARAMEL_DIAGNOSTICS"] = "mrdp" if agent
      tools.execute(binary, ["migrate"] + flags, project.root, settings)
    end

    # A new or newly set-up project starts migrated, so frappe dev serves it
    # at once.
    private def migrate_configured(project : Project, tools : Tools) : Nil
      @output.puts("Applying migrations…")
      values = development_environment(project).merge({"CARAMEL_ENV" => "development"})
      unless apply_migrations(project, tools, tools.compile(project), values).success?
        raise Error.new("Migrations were not applied; see the diagnostic above. Fix them, then run frappe migrate.")
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
      %w[DATABASE_URL MIGRATION_DATABASE_URL].each do |key|
        raise Error.new("#{key} differs from this project's Latte credentials; command refused") unless values[key]? == authoritative[key]?
      end
      raise Error.new("APP_ORIGIN differs from this project; run frappe setup") unless values["APP_ORIGIN"]? == project.origin
      values
    end

    private def services(action : String) : Int32
      client = LatteClient.new
      case action
      when "start" then client.ready!
      when "stop"  then client.stop_services
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
        "Managed Crystal compiler"    => -> { Tools.new(@framework_root).check_compiler },
        "Caramel installation"        => -> { verify_installation },
        "Locked dependencies"         => -> { Tools.new(@framework_root).check_dependencies(Project.load) },
        "Managed PostgreSQL tool"     => -> { Tools.new(@framework_root).toolchain.verify_postgres_version!; nil },
        "Private local configuration" => -> { Project.load.local_environment; nil },
        "Latte services"              => -> { document = LatteClient.new.status; raise Error.new("Latte services are not all running") unless document["services"].as_h.values.all? { |item| item["state"].as_s == "running" }; nil },
        "Named, trusted HTTPS"        => -> { verify_origin(Project.load) },
        "Port relay"                  => -> { verify_relay },
      }
      checks.each do |label, check|
        check.call
        @output.puts("OK    #{label}")
      rescue ex
        failures += 1
        @output.puts("CHECK #{label}: #{ex.is_a?(Error) ? ex.message : ex.class.to_s}")
      end
      failures == 0 ? 0 : 1
    end

    # A frappe older than 0.3.0 installed releases without their linter;
    # installing the release again builds it.
    private def verify_installation : Nil
      return if !Release.installed?(Installations.new, Caramel::VERSION, @framework_root) || Release.linter?(@framework_root)
      raise Error.new("Caramel #{Caramel::VERSION} was installed without its linter; finish it: frappe installations install #{Caramel::VERSION}")
    end

    private def verify_origin(project : Project) : Nil
      result = Latte::ProcessRunner.run(["/usr/bin/curl", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*", "--output", "/dev/null", "--write-out", "%{remote_ip}", project.origin + "/health"], timeout: 7.seconds, output_limit: 4096)
      unless result.success? && result.stdout == "127.0.0.1"
        raise Error.new("#{project.origin} must resolve to loopback with trusted HTTPS; check Latte DNS, port integration and certificate trust")
      end
    end

    # The resolver, the 80/443 relay and its launchd plist serve every
    # project, so they must be the ones the newest installed release installs
    # (ADR 0016). That release's installer compares them without sudo.
    private def verify_relay : Nil
      release, root = Installations.new.newest || {Caramel::VERSION, @framework_root}
      result = Latte::ProcessRunner.run([File.join(root, "scripts/install-local-integration"), "status"], chdir: root, timeout: 300.seconds, output_limit: 64 * 1024)
      raise Error.new("could not compare the installed port relay: #{result.stderr.strip}") unless result.success?
      states = JSON.parse(result.stdout).as_h.transform_values(&.as_s)
      return if states.values.all?("current")
      bundle = "/private/tmp/caramel-integration-bundle"
      prepare = "cd #{Process.quote(root)} && rm -rf #{bundle} && scripts/install-local-integration prepare #{bundle}"
      if states.values.all?("absent")
        raise Error.new("the .caramel resolver and ports 80/443 relay are not installed; install them: #{prepare} && sudo scripts/install-local-integration apply #{bundle}")
      end
      # apply refuses to replace another release's integration; uninstall
      # removes only files that still match that integration's receipt.
      stale = states.reject { |_, state| state == "current" }.keys
      raise Error.new("the installed #{stale.join(" and ")} #{stale.size == 1 ? "differs" : "differ"} from Caramel #{release}'s; replace them: #{prepare} && sudo scripts/install-local-integration uninstall && sudo scripts/install-local-integration apply #{bundle}")
    end

    private def sites : Nil
      LatteClient.new.sites.each do |site|
        state = site["state"]?.try(&.as_s?) || "unknown"
        state = "unknown" unless %w[running building build-error stopped unavailable unknown].includes?(state)
        owner = site["owner"]?.try(&.as_s?) == "terminal" ? " (terminal)" : ""
        @output.puts("#{site["name"].as_s.ljust(24)} #{(state + owner).ljust(24)} #{site["origin"].as_s}  #{site["directory"].as_s}")
      end
    end

    private def remove_site(name : String) : Nil
      client = LatteClient.new
      client.ready!
      entry = client.sites.find { |site| site["name"].as_s == name }
      raise Error.new("No registered site is named #{name}") unless entry
      id = entry["id"].as_s
      client.with_site_lock(id, name) { client.unregister(id) }
      @output.puts("Removed #{name} (#{entry["origin"].as_s}) from Latte. Its project folder, databases, credentials, logs and backups were kept. Run frappe setup in #{entry["directory"].as_s} to register it again.")
    end

    private def backup(restore : String?) : Nil
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
      if restore
        file = File.expand_path(restore)
        client.with_site_lock(site.id, project.name) do
          safety = dump_to.call("pre-restore")
          postgres.restore(site, file)
          @output.puts("Saved the current development database to #{safety}")
          @output.puts("Restored #{project.name} development database from #{file}")
        end
      else
        @output.puts("Saved #{project.name} development database: #{dump_to.call("development")}")
      end
    rescue Latte::Postgres::SecretMissing
      raise Error.new("frappe db: #{project.try(&.name) || "this project"} has no provisioned database; run frappe setup first")
    rescue ex : Latte::Postgres::Error | Latte::OwnershipError | ArgumentError
      raise Error.new("frappe db: #{ex.message}")
    end

    # `create` prints only the branch's runtime URL on stdout, so it can be
    # captured; the confirmation goes to stderr.
    private def branch(invocation : Commands::Invocation) : Nil
      name = invocation["NAME"]?.try { |value| branch_name!(invocation, value) }
      project = Project.load
      client = LatteClient.new
      client.ready!
      id = Latte::Site.id_for(project.name, project.root, project.metadata.domain_suffix)
      case invocation.command.name
      when "db branch create"
        branch = name || raise Error.new("frappe db branch create needs NAME")
        url = client.create_branch(id, branch)["runtime_url"].as_s
        @error.puts("Created database branch #{name} from #{project.name}'s development database.")
        @output.puts(url)
      when "db branch list"
        names = client.branches(id).compact_map(&.["name"].as_s?)
        names.each { |entry| @output.puts(entry) }
        @error.puts("#{project.name} has no database branches.") if names.empty?
      else
        branch = name || raise Error.new("frappe db branch delete needs NAME")
        client.drop_branch(id, branch)
        @output.puts("Deleted database branch #{name}.")
      end
    end

    private def branch_name!(invocation : Commands::Invocation, name : String) : String
      return name if name.matches?(Latte::Postgres::BRANCH_NAME)
      raise Commands::Usage.new("branch name #{name} must be a lowercase letter followed by up to 30 lowercase letters, digits or underscores",
        "frappe #{invocation.command.name}", [invocation.command])
    end

    private def logs(kind : String, follow : Bool) : Int32
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

    # ameba:disable Metrics/CyclomaticComplexity -- one branch per installations subcommand
    private def installations(invocation : Commands::Invocation) : Nil
      registry = Installations.new
      case invocation.command.name
      when "installations"
        entries = registry.list
        if entries.empty?
          @output.puts("No Caramel releases are installed. Run frappe installations install VERSION, or frappe installations register from a Caramel checkout.")
        else
          current = File.realpath(@framework_root)
          entries.keys.sort_by! { |release| SemanticVersion.parse(release) }.each do |release|
            root = entries[release]
            @output.puts("#{release.ljust(12)} #{root}#{root == current ? "  (this installation)" : ""}")
          end
        end
      when "installations register"
        root = File.realpath(@framework_root)
        {"frappe" => "scripts/build-frappe", "latte" => "scripts/build-latte"}.each do |name, build|
          binary = File.join(root, "bin", name)
          info = File.info?(binary, follow_symlinks: false)
          unless info && info.file? && File::Info.executable?(binary)
            raise Error.new("#{binary} is missing; run #{build} first")
          end
        end
        previous = registry.register(Caramel::VERSION, root)
        @output.puts("Registered Caramel #{Caramel::VERSION}: #{root}#{previous && previous != root ? " (replaced #{previous})" : ""}")
        follow(registry)
      when "installations install"
        release = invocation["VERSION"]
        if root = registry.lookup(release)
          if Release.new(release, registry, @output, @error).finish(root)
            @output.puts("Finished installing Caramel #{release}: #{root}")
          else
            @output.puts("Caramel #{release} is already installed: #{root}")
          end
          return
        end
        root = Release.new(release, registry, @output, @error).install(Tools.new(@framework_root).toolchain.root)
        @output.puts("Installed Caramel #{release}: #{root}")
        follow(registry)
      else
        release = invocation["VERSION"]
        root = registry.lookup(release)
        raise Error.new("Caramel #{release} is not registered") unless root && registry.remove(release)
        @output.puts("Removed Caramel #{release} from the installation registry.")
        follow(registry, root)
      end
    end

    # Leaves ~/.local/bin/frappe and latte on the newest installed release.
    private def follow(registry : Installations, previous : String? = nil) : Nil
      launchers = Launchers.new
      if root = launchers.follow(registry, previous)
        release = registry.newest.try(&.[0])
        @output.puts("#{launchers.path("frappe")} and #{launchers.path("latte")} run the newest installed release, Caramel #{release}: #{root}")
        @output.puts("Add #{launchers.directory} to PATH to run them by name.") unless launchers.on_path?
      else
        @output.puts("No Caramel release remains installed; the #{launchers.directory} launchers Caramel wrote were removed.")
      end
    end
  end
end
