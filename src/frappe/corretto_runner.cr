require "./project"
require "./tools"
require "./latte_client"
require "../caramel/database"
require "../latte/postgres"

module Caramel::Frappe
  # `frappe corretto [SPEC_PATHS...] [--concurrency=N]` (RFC-0006): refuses
  # mocking APIs under spec/, migrates the spec template database once, clones
  # one Latte test-worker database per worker from it, deals the spec files
  # round-robin to N parallel spec processes and drops the workers.
  class CorrettoRunner
    MOCKING = /(?<![\w.:@$])(?:allow|receive|double|instance_double|mock)\(|\.stub\(/

    record Violation, path : String, line : Int32, call : String

    # Every spec file the paths name (directories contribute their `*_spec.cr`
    # files), relative to the project root and sorted.
    def self.spec_files(root : String, paths : Array(String)) : Array(String)
      files = paths.flat_map do |path|
        full = File.expand_path(path, root)
        raise Error.new("Spec paths must be inside the project: #{path}") unless full == root || full.starts_with?(root + "/")
        if File.directory?(full)
          Dir.glob(File.join(full, "**/*_spec.cr"))
        elsif File.file?(full) && full.ends_with?(".cr")
          [full]
        else
          raise Error.new("No spec file or directory at #{path}")
        end
      end
      relative = files.map { |file| Path[file].relative_to(root).to_s }.uniq!.sort!
      raise Error.new("No *_spec.cr files under #{paths.join(", ")}") if relative.empty?
      relative
    end

    # Deals files to at most `workers` groups like cards, so every group gets work.
    def self.split(files : Array(String), workers : Int32) : Array(Array(String))
      groups = Array.new(Math.min(workers, files.size)) { [] of String }
      files.each_with_index { |file, index| groups[index % groups.size] << file }
      groups
    end

    # Mocking calls in any Crystal file under spec/, skipping comment lines.
    def self.scan(root : String) : Array(Violation)
      Dir.glob(File.join(root, "spec/**/*.cr")).sort.flat_map do |path|
        relative = Path[path].relative_to(root).to_s
        violations = [] of Violation
        File.read_lines(path).each_with_index(1) do |line, number|
          next if line.lstrip.starts_with?('#')
          if match = line.match(MOCKING)
            violations << Violation.new(relative, number, match[0])
          end
        end
        violations
      end
    end

    def initialize(@framework_root : String, @project : Project, @output : IO, @error : IO)
    end

    def run(paths : Array(String), concurrency : Int32) : Nil
      files = self.class.spec_files(@project.root, paths)
      refuse_mocks
      client = LatteClient.new
      client.ready!
      id = Latte::Site.id_for(@project.name, @project.root, @project.metadata.domain_suffix)
      template = verified_template(client, id)
      tools = Tools.new(@framework_root, @output, @error)
      tools.app_command(@project, ["migrate"], {
        "CARAMEL_ENV" => "test", "CARAMEL_SPEC_DATABASE" => Caramel::Database::Config.parse(template["SPEC_DATABASE_URL"]).database,
        "SPEC_DATABASE_URL" => template["SPEC_DATABASE_URL"], "SPEC_MIGRATION_DATABASE_URL" => template["SPEC_MIGRATION_DATABASE_URL"],
        "CARAMEL_EXPECTED_DATABASE_URL" => template["SPEC_MIGRATION_DATABASE_URL"],
      })
      groups = self.class.split(files, concurrency)
      secret = Random::Secure.hex(32)
      created = [] of Int32
      results = begin
        environments = groups.map_with_index do |_, offset|
          index = offset + 1
          worker = client.test_worker(id, index)
          created << index
          worker_environment(client, id, index, worker, secret)
        end
        @output.puts("Corretto: #{files.size} spec file#{files.size == 1 ? "" : "s"} across #{groups.size} worker#{groups.size == 1 ? "" : "s"}")
        run_workers(tools, groups, environments)
      ensure
        created.each do |index|
          client.drop_test_worker(id, index)
        rescue ex : Error
          @error.puts("Could not drop test worker #{index}: #{ex.message}")
        end
      end
      failed = results.each_with_index.reject { |passed, _| passed }.map { |_, offset| "w#{offset + 1}" }.to_a
      @output.puts("Corretto: #{results.size - failed.size} of #{results.size} workers passed")
      raise Error.new("Specs failed in #{failed.join(", ")}; see the prefixed output above") unless failed.empty?
    end

    private def refuse_mocks : Nil
      violations = self.class.scan(@project.root)
      return if violations.empty?
      violations.each { |violation| @error.puts("#{violation.path}:#{violation.line}: `#{violation.call}` is a mocking API; Corretto forbids mocks") }
      @error.puts("  Remediation: assert on observable ingress, database rows and rendered hypermedia; fake third-party HTTP at the wire with Corretto.stub_wire.")
      raise Error.new("Specs refused: #{violations.size} mocking call#{violations.size == 1 ? "" : "s"} under spec/")
    end

    # The spec template URLs, verified to be this project's isolated spec database.
    private def verified_template(client : LatteClient, id : String) : Hash(String, String)
      authoritative = client.environment(id, @project.root)
      local = @project.local_environment
      %w[SPEC_DATABASE_URL SPEC_MIGRATION_DATABASE_URL].each do |key|
        raise Error.new("#{key} differs from this project's Latte credentials; specs refused") unless local[key]? == authoritative[key]?
      end
      config = Caramel::Database::Config.parse(authoritative["SPEC_DATABASE_URL"])
      migration = Caramel::Database::Config.parse(authoritative["SPEC_MIGRATION_DATABASE_URL"])
      development = Caramel::Database::Config.parse(authoritative["DATABASE_URL"])
      unless config.database == Latte::Postgres.database_names(id).spec && config.database != development.database &&
             migration.database == config.database && migration.host == config.host && migration.port == config.port
        raise Error.new("Spec database identity is not isolated from development; specs refused")
      end
      db = Caramel::Database.open(authoritative["SPEC_DATABASE_URL"], 1)
      begin
        unless db.query_one("SELECT current_database()", as: String) == config.database && db.query_one("SELECT current_user", as: String) == config.user
          raise Error.new("Connected spec database identity differs; specs refused")
        end
      ensure
        db.close
      end
      authoritative
    end

    private def worker_environment(client : LatteClient, id : String, index : Int32, worker : JSON::Any, secret : String) : Hash(String, String)
      database = Latte::Postgres.test_worker_database(id, index)
      runtime, migration = worker["runtime_url"].as_s, worker["migration_url"].as_s
      unless worker["database"].as_s == database && Caramel::Database::Config.parse(runtime).database == database && Caramel::Database::Config.parse(migration).database == database
        raise Error.new("Latte returned a different test worker database; specs refused")
      end
      {
        "CARAMEL_ENV" => "test", "CARAMEL_SPEC_DATABASE" => database,
        "APP_ORIGIN" => @project.origin, "APP_SECRET" => secret,
        "DATABASE_URL" => runtime, "MIGRATION_DATABASE_URL" => migration,
        "SPEC_DATABASE_URL" => runtime, "SPEC_MIGRATION_DATABASE_URL" => migration,
        "CARAMEL_EXPECTED_DATABASE_URL" => runtime,
        "CORRETTO_WORKER" => index.to_s, "CORRETTO_SITE" => id, "CORRETTO_LATTE_SOCKET" => client.socket_path,
      }
    end

    # Compiles and runs each group's specs in parallel, prefixing every line
    # of output with its worker, and returns whether each worker passed.
    # `crystal spec` would link every worker to the same temporary executable
    # in the shared compiler cache, so each worker builds its own binary.
    private def run_workers(tools : Tools, groups : Array(Array(String)), environments : Array(Hash(String, String))) : Array(Bool)
      directory = Latte::StateSecurity.ensure_owned_directory(File.join(@project.root, ".caramel"))
      finished = Channel({Int32, Bool}).new
      groups.each_with_index do |group, offset|
        spawn do
          prefix = "[w#{offset + 1}] "
          env = tools.environment(environments[offset])
          binary = File.join(directory, "corretto-w#{offset + 1}")
          passed = begin
            relayed(File.join(@framework_root, "scripts/crystal"), ["build", *group, "-o", binary], env, prefix) &&
            relayed(binary, [] of String, env, prefix)
          rescue ex : IO::Error | File::Error
            @error.puts("#{prefix}#{ex.message}")
            false
          ensure
            File.delete?(binary)
            File.delete?("#{binary}.dwarf")
          end
          finished.send({offset, passed})
        end
      end
      results = Array(Bool).new(groups.size, false)
      groups.size.times do
        offset, passed = finished.receive
        results[offset] = passed
      end
      results
    end

    private def relayed(command : String, args : Array(String), env : Hash(String, String), prefix : String) : Bool
      process = Process.new(command, args, chdir: @project.root, env: env, clear_env: true,
        input: Process::Redirect::Close, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
      done = Channel(Nil).new(2)
      spawn { relay(process.output, @output, prefix); done.send(nil) }
      spawn { relay(process.error, @error, prefix); done.send(nil) }
      2.times { done.receive }
      process.wait.success?
    end

    private def relay(source : IO, destination : IO, prefix : String) : Nil
      source.each_line(chomp: false) do |line|
        destination << prefix << line
        destination << '\n' unless line.ends_with?('\n')
        destination.flush
      end
    end
  end
end
