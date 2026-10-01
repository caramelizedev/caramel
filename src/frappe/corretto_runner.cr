require "digest/sha256"
require "./project"
require "./tools"
require "./build_slot"
require "./dev_files"
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

    # What a suite that mocks does instead.
    MOCKS_REMEDIATION = "  Remediation: assert on observable ingress, database rows " \
                        "and rendered hypermedia; fake third-party HTTP at the wire " \
                        "with Corretto.stub_wire."

    record Violation, path : String, line : Int32, call : String

    # Every spec file the paths name (directories contribute their `*_spec.cr`
    # files), relative to the project root and sorted.
    def self.spec_files(root : String, paths : Array(String)) : Array(String)
      files = paths.flat_map do |path|
        full = File.expand_path(path, root)
        inside = full == root || full.starts_with?(root + "/")
        raise Error.new("Spec paths must be inside the project: #{path}") unless inside
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

    # Keys Corretto, the toolchain or the dynamic loader own; .env.test may
    # not set them.
    RESERVED_TEST_KEYS = %w[
      APP_ORIGIN APP_SECRET DATABASE_URL MIGRATION_DATABASE_URL
      PATH HOME USER LOGNAME TMPDIR LANG
    ]
    RESERVED_TEST_PREFIXES = %w[SPEC_ CARAMEL_ CORRETTO_ CRYSTAL_ LD_ DYLD_]

    # The application's own test settings, such as a webhook secret, from the
    # committed `.env.test`: test-only values every spec worker receives.
    # Development `.env` values never reach specs.
    def self.test_environment(root : String) : Hash(String, String)
      path = File.join(root, ".env.test")
      info = File.info?(path, follow_symlinks: false) || return {} of String => String
      raise Error.new(".env.test must be a regular file") unless info.file?
      raise Error.new(".env.test exceeds 64 KiB") if info.size > 65_536

      values = LocalEnvironment.parse(File.read(path))
      reserved = values.keys.select { |key| reserved_test_key?(key) }
      return values if reserved.empty?

      raise Error.new(".env.test cannot set #{reserved.join(", ")}; " +
                      "Corretto and the toolchain supply these")
    end

    private def self.reserved_test_key?(key : String) : Bool
      return true if RESERVED_TEST_KEYS.includes?(key)

      RESERVED_TEST_PREFIXES.any? { |prefix| key.starts_with?(prefix) }
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
      settings = self.class.test_environment(@project.root)
      refuse_mocks
      client = LatteClient.new
      client.ready!
      id = Latte::Site.id_for(@project.name, @project.root, @project.metadata.domain_suffix)
      template = verified_template(client, id)
      tools = Tools.new(@framework_root, @output, @error)
      spec_url = template["SPEC_DATABASE_URL"]
      spec_database = Caramel::Database::Config.parse(spec_url).database
      migration_url = template["SPEC_MIGRATION_DATABASE_URL"]
      groups = self.class.split(files, concurrency)
      # Spec binaries need no database, so they build while the application
      # builds and migrates the template and Latte clones the workers.
      builds = start_builds(tools, groups)
      secret = Random::Secure.hex(32)
      created = [] of Int32
      results = begin
        tools.app_command(@project, ["migrate"], settings.merge({
          "CARAMEL_ENV"                   => "test",
          "CARAMEL_SPEC_DATABASE"         => spec_database,
          "SPEC_DATABASE_URL"             => spec_url,
          "SPEC_MIGRATION_DATABASE_URL"   => migration_url,
          "CARAMEL_EXPECTED_DATABASE_URL" => migration_url,
        }))
        environments = groups.map_with_index do |_, offset|
          index = offset + 1
          worker = client.test_worker(id, index)
          created << index
          settings.merge(worker_environment(client, id, index, worker, secret))
        end
        file_count = pluralize(files.size, "spec file")
        worker_count = pluralize(groups.size, "worker")
        @output.puts("Corretto: #{file_count} across #{worker_count}")
        run_workers(tools, builds, environments)
      ensure
        # A failed migration or clone still waits for the builds it started.
        builds.each(&.receive?)
        created.each do |index|
          client.drop_test_worker(id, index)
        rescue ex : Error
          @error.puts("Could not drop test worker #{index}: #{ex.message}")
        end
      end
      failed = results.each_with_index
        .reject { |passed, _| passed }
        .map { |_, offset| "w#{offset + 1}" }
        .to_a
      @output.puts("Corretto: #{results.size - failed.size} of #{results.size} workers passed")
      return if failed.empty?

      raise Error.new("Specs failed in #{failed.join(", ")}; " \
                      "see the prefixed output above")
    end

    # *number* of *noun*, as in `1 worker` or `3 workers`.
    private def pluralize(number : Int32, noun : String) : String
      "#{number} #{noun}#{number == 1 ? "" : "s"}"
    end

    private def refuse_mocks : Nil
      violations = self.class.scan(@project.root)
      return if violations.empty?
      violations.each do |violation|
        @error.puts("#{violation.path}:#{violation.line}: `#{violation.call}` " \
                    "is a mocking API; Corretto forbids mocks")
      end
      @error.puts(MOCKS_REMEDIATION)
      calls = pluralize(violations.size, "mocking call")
      raise Error.new("Specs refused: #{calls} under spec/")
    end

    # The spec template URLs, verified to be this project's isolated spec database.
    private def verified_template(client : LatteClient, id : String) : Hash(String, String)
      authoritative = client.environment(id, @project.root)
      local = @project.local_environment
      %w[SPEC_DATABASE_URL SPEC_MIGRATION_DATABASE_URL].each do |key|
        next if local[key]? == authoritative[key]?
        raise Error.new("#{key} differs from this project's Latte credentials; " \
                        "specs refused")
      end
      config = Caramel::Database::Config.parse(authoritative["SPEC_DATABASE_URL"])
      migration = Caramel::Database::Config.parse(authoritative["SPEC_MIGRATION_DATABASE_URL"])
      development = Caramel::Database::Config.parse(authoritative["DATABASE_URL"])
      unless config.database == Latte::Postgres.database_names(id).spec &&
             config.database != development.database &&
             migration.database == config.database &&
             migration.host == config.host && migration.port == config.port
        raise Error.new("Spec database identity is not isolated from development; " \
                        "specs refused")
      end
      db = Caramel::Database.open(authoritative["SPEC_DATABASE_URL"], 1)
      begin
        unless db.query_one("SELECT current_database()", as: String) == config.database &&
               db.query_one("SELECT current_user", as: String) == config.user
          raise Error.new("Connected spec database identity differs; specs refused")
        end
      ensure
        db.close
      end
      authoritative
    end

    private def worker_environment(client : LatteClient,
                                   id : String,
                                   index : Int32,
                                   worker : JSON::Any,
                                   secret : String) : Hash(String, String)
      database = Latte::Postgres.test_worker_database(id, index)
      runtime, migration = worker["runtime_url"].as_s, worker["migration_url"].as_s
      unless worker["database"].as_s == database &&
             Caramel::Database::Config.parse(runtime).database == database &&
             Caramel::Database::Config.parse(migration).database == database
        raise Error.new("Latte returned a different test worker database; specs refused")
      end
      {
        "CARAMEL_ENV"                   => "test",
        "CARAMEL_SPEC_DATABASE"         => database,
        "APP_ORIGIN"                    => @project.origin,
        "APP_SECRET"                    => secret,
        "DATABASE_URL"                  => runtime,
        "MIGRATION_DATABASE_URL"        => migration,
        "SPEC_DATABASE_URL"             => runtime,
        "SPEC_MIGRATION_DATABASE_URL"   => migration,
        "CARAMEL_EXPECTED_DATABASE_URL" => runtime,
        "CORRETTO_WORKER"               => index.to_s,
        "CORRETTO_SITE"                 => id,
        "CORRETTO_LATTE_SOCKET"         => client.socket_path,
      }
    end

    # Starts building each group's spec binary in its own fiber. Each channel
    # yields the binary, or nil when its build failed, and then closes.
    # `crystal spec` would link every worker to the same temporary executable
    # in the shared compiler cache, so each worker builds its own binary. It
    # compiles a generated `.caramel/corretto/w<N>.cr` that requires the
    # group's files in order: the compiler names a program's cache directory
    # after that stable path, not after whichever spec file sorts first, so a
    # run over other files reuses the worker's objects. The binary stays in
    # `.caramel/corretto/` and runs again while the application's sources,
    # spec/, the group's files, the toolchain and the framework are unchanged.
    # It builds in the development build's environment; the worker's
    # settings apply only when it runs.
    private def start_builds(tools : Tools, groups : Array(Array(String))) : Array(Channel(String?))
      Latte::StateSecurity.ensure_owned_directory(File.join(@project.root, ".caramel"))
      corretto = File.join(@project.root, ".caramel/corretto")
      entries = Latte::StateSecurity.ensure_owned_directory(corretto)
      remove_idle_workers(entries, groups.size)
      signature = source_signature
      groups.map_with_index do |group, offset|
        build = Channel(String?).new(1)
        spawn do
          prefix = "[w#{offset + 1}] "
          binary = begin
            worker_binary(tools, entries, offset + 1, group, signature, prefix)
          rescue ex
            @error.puts("#{prefix}#{ex.message}")
            nil
          end
          build.send(binary)
          build.close
        end
        build
      end
    end

    # Runs each worker's spec binary once it is built, in parallel, prefixing
    # every line of output with its worker, and returns whether each passed.
    private def run_workers(tools : Tools,
                            builds : Array(Channel(String?)),
                            environments : Array(Hash(String, String))) : Array(Bool)
      finished = Channel({Int32, Bool}).new
      builds.each_with_index do |build, offset|
        spawn do
          prefix = "[w#{offset + 1}] "
          env = tools.environment(environments[offset])
          passed = begin
            binary = build.receive?
            binary ? relayed(binary, [] of String, env, prefix) : false
          rescue ex : IO::Error | File::Error | Error
            @error.puts("#{prefix}#{ex.message}")
            false
          end
          finished.send({offset, passed})
        end
      end
      results = Array(Bool).new(builds.size, false)
      builds.size.times do
        offset, passed = finished.receive
        results[offset] = passed
      end
      results
    end

    # The application's and spec/'s sources, hashed as `frappe dev` hashes
    # them. Nil when they cannot be hashed; no spec binary is then reused.
    private def source_signature : String?
      files = DevFiles.new(@project.root)
      "#{files.snapshot.source}\n#{files.spec_signature}"
    rescue Error
      nil
    end

    # Worker *index*'s spec binary: the one it kept when that was built from
    # the same sources and files, or a new build. Nil when the build fails.
    private def worker_binary(tools : Tools,
                              entries : String,
                              index : Int32,
                              group : Array(String),
                              signature : String?,
                              prefix : String) : String?
      name = "w#{index}"
      entry = File.join(entries, "#{name}.cr")
      requires = entry_source(group)
      File.write(entry, requires)
      record = File.join(entries, "#{name}.json")
      slot = BuildSlot.new(File.join(entries, name), record, tools.toolchain.root, "corretto")
      fingerprint = signature.try { |value| Digest::SHA256.hexdigest("#{value}\n#{requires}") }
      return slot.binary if fingerprint && slot.holds?(fingerprint)
      temporary = File.join(entries, "building-#{name}-#{Random::Secure.hex(4)}")
      begin
        compiler = File.join(@framework_root, "scripts/crystal")
        arguments = ["build", entry, "-o", temporary]
        return unless relayed(compiler, arguments, tools.environment, prefix)
        slot.install(temporary, fingerprint)
        slot.binary
      ensure
        File.delete?(temporary)
        File.delete?(temporary + ".dwarf")
      end
    end

    # Deletes the spec binaries of workers beyond this run's.
    private def remove_idle_workers(entries : String, workers : Int32) : Nil
      Dir.children(entries).each do |name|
        match = name.match(/\Aw(\d+)(?:\.dwarf|\.json)?\z/) || next
        path = File.join(entries, name)
        File.delete(path) if match[1].to_i > workers && File.file?(path) && !File.symlink?(path)
      end
    end

    # A program, in .caramel/corretto/, that requires the group's spec files
    # in order.
    private def entry_source(group : Array(String)) : String
      group.join { |file| "require #{("../../" + file.rchop(".cr")).inspect}\n" }
    end

    private def relayed(command : String,
                        args : Array(String),
                        env : Hash(String, String),
                        prefix : String) : Bool
      process = Process.new(command, args,
        chdir: @project.root, env: env, clear_env: true,
        input: Process::Redirect::Close,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)
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
