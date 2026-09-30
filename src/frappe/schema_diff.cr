require "random/secure"
require "../caramel/database"
require "../sugar_orm/catalog"
require "../sugar_orm/introspection"
require "../sugar_orm/differ"
require "../sugar_orm/ddl"
require "../sugar_orm/linter"
require "../sugar_orm/migration"
require "./latte_client"
require "./tools"

module Caramel::Frappe
  # `frappe db diff`: derives migrations by diffing the application's declared
  # schema against a disposable Latte branch of the development database, and
  # proves them on that branch before keeping them (RFC-0002 §2.5).
  class SchemaDiff
    NAME           = /\A[a-z][a-z0-9_]{0,62}\z/
    VERSION        = "%Y%m%d%H%M%S"
    MIGRATION_FILE = /\A(\d+)_.*\.cr\z/

    UNCHANGED = "The development database already matches the declared schema; " \
                "no migration was written."
    UNVERIFIED = "Verification failed: after the new migrations ran on a scratch " \
                 "branch, it still differs from the declared schema:"

    @agent = false

    def initialize(@project : Project,
                   @tools : Tools,
                   @client : LatteClient,
                   @output : IO = STDOUT,
                   @error : IO = STDERR)
    end

    # Returns the written migration files relative to the project root. With
    # `agent`, halts and lint refusals raise as MRDP (RFC-0005 §2.3).
    def run(name : String, dev_override : Bool, agent : Bool = false) : Array(String)
      @agent = agent
      unless name.matches?(NAME)
        raise Error.new("Migration name must be lowercase snake_case starting with " \
                        "a letter, such as create_books")
      end
      site = Latte::Site.id_for(@project.name, @project.root, @project.metadata.domain_suffix)
      binary = @tools.compile(@project)
      declared = declared(binary)
      scratch = "diff_#{Random::Secure.hex(4)}"
      branch = @client.create_branch(site, scratch)
      written = [] of String
      begin
        # Pending migrations first, so the diff starts from the full history.
        migrate(binary, branch, dev_override)
        plan = SugarORM::Differ.diff(declared, introspect(branch), dev_override)
        plan.notes.each { |note| @output.puts("Note: #{note}") }
        raise Error.new(halted(plan)) unless plan.halts.empty?
        plan.overridden.each { |halt| @error.puts("WARN (--dev-override) #{halt}") }
        if plan.empty?
          @output.puts(UNCHANGED)
          return written
        end
        migrations = migrations(name, plan)
        begin
          violations = SugarORM::Linter.lint(migrations)
          SugarORM::Linter.enforce(violations, dev_override, "development", @error)
        rescue ex : SugarORM::Linter::Refused
          raise Error.new(ex.to_mrdp(@project.root).rstrip) if agent
          raise Error.new("#{ex.message}\nNo migration was written.")
        end
        migrations.each do |migration|
          path = "db/migrations/#{migration.version}_#{migration.name}.cr"
          File.write(File.join(@project.root, path), SchemaDiff.source(migration))
          written << path
        end
        migrate(@tools.compile(@project), branch, dev_override)
        verification = SugarORM::Differ.diff(declared, introspect(branch))
        raise Error.new("#{UNVERIFIED}\n#{verification}") unless verification.clean?
        written.each { |path| @output.puts("Wrote #{path}") }
        written
      rescue ex
        written.each { |path| File.delete?(File.join(@project.root, path)) }
        if ex.is_a?(Error) && !written.empty?
          raise Error.new("#{ex.message}\nRemoved #{written.join(", ")}.")
        end
        raise ex
      ensure
        begin
          @client.drop_branch(site, scratch)
        rescue ex : Error
          @error.puts("Could not drop the scratch branch #{scratch}: #{ex.message}")
        end
      end
    end

    private def declared(binary : String) : Array(SugarORM::Catalog::Table)
      development = {"CARAMEL_ENV" => "development"}
      status, document = @tools.capture(binary, ["schema"], @project.root, development)
      unless status.success?
        raise Error.new("The application's schema command failed; " \
                        "see the diagnostic above")
      end
      SugarORM::Catalog.from_json(document)
    rescue ex : ArgumentError
      raise Error.new("The application printed an unreadable schema document: #{ex.message}")
    end

    # The branch run repeats warnings Frappé already printed; its output
    # appears only when it fails.
    private def migrate(binary : String, branch : JSON::Any, dev_override : Bool) : Nil
      url = branch["migration_url"].as_s
      values = {
        "CARAMEL_ENV"                   => "development",
        "MIGRATION_DATABASE_URL"        => url,
        "DATABASE_URL"                  => branch["runtime_url"].as_s,
        "CARAMEL_EXPECTED_DATABASE_URL" => url,
      }
      values["CARAMEL_DIAGNOSTICS"] = "mrdp" if @agent
      diagnostics = IO::Memory.new
      command = dev_override ? ["migrate", "--dev-override"] : ["migrate"]
      status, output = @tools.capture(binary, command, @project.root, values, diagnostics)
      return if status.success?
      @error.print(output, diagnostics)
      raise Error.new("Migrating the scratch branch failed; see the diagnostic above")
    end

    private def introspect(branch : JSON::Any) : SugarORM::Introspection::Snapshot
      db = Caramel::Database.open(branch["runtime_url"].as_s, 1)
      begin
        SugarORM::Introspection.read(db)
      ensure
        db.close
      end
    end

    private def halted(plan : SugarORM::Differ::Plan) : String
      return String.build { |io| plan.halts.each(&.to_mrdp(io)) }.rstrip if @agent
      halts = plan.halts.join("\n\n")
      message = "frappe db diff halted; no migration was written.\n\n#{halts}"
      return message unless plan.halts.any?(&.overridable)
      "#{message}\n\nIn development, frappe db diff --dev-override derives " \
      "overridable changes anyway."
    end

    # One transactional migration, plus a separate autocommit migration for
    # CONCURRENTLY index changes and foreign key validation.
    private def migrations(name : String,
                           plan : SugarORM::Differ::Plan) : Array(SugarORM::Migration)
      latest = latest_version
      parts = [] of Tuple(String, Array(String))
      unless plan.transactional.empty?
        parts << {name, SugarORM::DDL.statements(plan.transactional)}
      end
      unless plan.online.empty?
        online_name = parts.empty? ? name : "#{name}_concurrently"
        parts << {online_name, SugarORM::DDL.statements(plan.online)}
      end
      now = Time.utc
      parts.map do |label, statements|
        latest = next_version(now, latest)
        path = File.join(@project.root, "db/migrations/#{latest}_#{label}.cr")
        SugarORM::Migration.new(latest, label, statements, path)
      end
    end

    # The newest version among the project's migration files; 0 when none.
    private def latest_version : Int64
      files = Dir.children(File.join(@project.root, "db/migrations"))
      versions = files.compact_map(&.match(MIGRATION_FILE).try(&.[1].to_i64?))
      versions.max? || 0_i64
    end

    private def next_version(now : Time, latest : Int64) : Int64
      candidate = now.to_s(VERSION).to_i64
      return candidate if candidate > latest
      begin
        (Time.parse_utc(latest.to_s, VERSION) + 1.second).to_s(VERSION).to_i64
      rescue Time::Format::Error
        latest + 1
      end
    end

    # What Ameba's Style/HeredocEscape accepts as a reason to quote a heredoc:
    # interpolation or one of Crystal's escape sequences.
    ESCAPES = "[abefnrtv]|[CdDhHRsSvVwWX]|[0-7]{1,3}|" \
              "x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|u\\{[0-9a-fA-F]{1,6}\\}"
    ESCAPE = /#\{|\\(?:#{ESCAPES})/

    # The first line of every migration file.
    PREAMBLE = "# Derived from the declared schema. Once applied, a migration is " \
               "immutable: change the schema and run frappe db diff again.\n"

    # The migration file; `frappe make resource` writes the same bytes for a
    # new table, so a generated migration is exactly what a diff would derive.
    def self.source(migration : SugarORM::Migration) : String
      String.build do |io|
        io << PREAMBLE
        io << "App::MIGRATIONS << SugarORM::Migration.new("
        io << migration.version << "_i64, " << migration.name.inspect << ", [\n"
        migration.statements.each do |statement|
          # Quoted only when interpolation or backslashes must stay literal.
          literal = statement.matches?(/#\{|\\/)
          if literal && !statement.matches?(ESCAPE)
            io << "  # ameba:disable Style/HeredocEscape -- " \
                  "its backslashes stay literal\n"
          end
          io << (literal ? "  <<-'SQL',\n" : "  <<-SQL,\n")
          statement.each_line { |line| io << "    " << line << '\n' }
          io << "    SQL\n"
        end
        io << "])\n"
      end
    end
  end
end
