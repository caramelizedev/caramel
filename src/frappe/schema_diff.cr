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
    NAME    = /\A[a-z][a-z0-9_]{0,62}\z/
    VERSION = "%Y%m%d%H%M%S"

    @agent = false

    def initialize(@project : Project, @tools : Tools, @client : LatteClient, @output : IO = STDOUT, @error : IO = STDERR)
    end

    # Returns the written migration files relative to the project root. With
    # `agent`, halts and lint refusals raise as MRDP (RFC-0005 §2.3).
    def run(name : String, dev_override : Bool, agent : Bool = false) : Array(String)
      @agent = agent
      raise Error.new("Migration name must be lowercase snake_case starting with a letter, such as create_books") unless name.matches?(NAME)
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
          @output.puts("The development database already matches the declared schema; no migration was written.")
          return written
        end
        migrations = migrations(name, plan)
        begin
          SugarORM::Linter.enforce(SugarORM::Linter.lint(migrations), dev_override, "development", @error)
        rescue ex : SugarORM::Linter::Refused
          raise Error.new(agent ? ex.to_mrdp(@project.root).rstrip : "#{ex.message}\nNo migration was written.")
        end
        migrations.each do |migration|
          path = "db/migrations/#{migration.version}_#{migration.name}.cr"
          File.write(File.join(@project.root, path), SchemaDiff.source(migration))
          written << path
        end
        migrate(@tools.compile(@project), branch, dev_override)
        verification = SugarORM::Differ.diff(declared, introspect(branch))
        unless verification.clean?
          raise Error.new("Verification failed: after the new migrations ran on a scratch branch, it still differs from the declared schema:\n#{verification}")
        end
        written.each { |path| @output.puts("Wrote #{path}") }
        written
      rescue ex
        written.each { |path| File.delete?(File.join(@project.root, path)) }
        raise Error.new("#{ex.message}\nRemoved #{written.join(", ")}.") if ex.is_a?(Error) && !written.empty?
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
      status, document = @tools.capture(binary, ["schema"], @project.root, {"CARAMEL_ENV" => "development"})
      raise Error.new("The application's schema command failed; see the diagnostic above") unless status.success?
      SugarORM::Catalog.from_json(document)
    rescue ex : ArgumentError
      raise Error.new("The application printed an unreadable schema document: #{ex.message}")
    end

    # The branch run repeats warnings Frappé already printed; its output
    # appears only when it fails.
    private def migrate(binary : String, branch : JSON::Any, dev_override : Bool) : Nil
      url = branch["migration_url"].as_s
      values = {"CARAMEL_ENV" => "development", "MIGRATION_DATABASE_URL" => url, "DATABASE_URL" => branch["runtime_url"].as_s, "CARAMEL_EXPECTED_DATABASE_URL" => url}
      values["CARAMEL_DIAGNOSTICS"] = "mrdp" if @agent
      diagnostics = IO::Memory.new
      status, output = @tools.capture(binary, dev_override ? ["migrate", "--dev-override"] : ["migrate"], @project.root, values, diagnostics)
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
      message = "frappe db diff halted; no migration was written.\n\n#{plan.halts.join("\n\n")}"
      plan.halts.any?(&.overridable) ? "#{message}\n\nIn development, frappe db diff --dev-override derives overridable changes anyway." : message
    end

    # One transactional migration, plus a separate autocommit migration for
    # CONCURRENTLY index changes and foreign key validation.
    private def migrations(name : String, plan : SugarORM::Differ::Plan) : Array(SugarORM::Migration)
      latest = Dir.children(File.join(@project.root, "db/migrations")).compact_map { |file| file.match(/\A(\d+)_.*\.cr\z/).try(&.[1].to_i64?) }.max? || 0_i64
      parts = [] of Tuple(String, Array(String))
      parts << {name, SugarORM::DDL.statements(plan.transactional)} unless plan.transactional.empty?
      parts << {parts.empty? ? name : "#{name}_concurrently", SugarORM::DDL.statements(plan.online)} unless plan.online.empty?
      now = Time.utc
      parts.map do |label, statements|
        latest = next_version(now, latest)
        SugarORM::Migration.new(latest, label, statements, File.join(@project.root, "db/migrations/#{latest}_#{label}.cr"))
      end
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

    # The migration file; `frappe make resource` writes the same bytes for a
    # new table, so a generated migration is exactly what a diff would derive.
    def self.source(migration : SugarORM::Migration) : String
      String.build do |io|
        io << "# Derived from the declared schema. Once applied, a migration is immutable: change the schema and run frappe db diff again.\n"
        io << "App::MIGRATIONS << SugarORM::Migration.new(" << migration.version << "_i64, " << migration.name.inspect << ", [\n"
        migration.statements.each do |statement|
          # Quoted only when interpolation or escapes must stay literal.
          io << (statement.matches?(/#\{|\\/) ? "  <<-'SQL',\n" : "  <<-SQL,\n")
          statement.each_line { |line| io << "    " << line << '\n' }
          io << "    SQL\n"
        end
        io << "])\n"
      end
    end
  end
end
