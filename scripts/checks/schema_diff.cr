require "./support/latte_fixture"
require "uri"
require "http/params"

module Caramel::Checks
  # End-to-end branch-and-diff: a generated project evolves a SugarORM schema
  # through frappe db diff and frappe migrate against a disposable Latte.
  class SchemaDiff < LatteFixture
    COMPILE = 300.seconds

    def initialize
      toolchain = Checks.toolchain_root("Set CARAMEL_TOOLCHAIN_ROOT to the managed toolchain")
      super("caramel-schema-diff-")
      @psql = File.join(toolchain, "data/installs/conda-postgresql/18.6/bin/psql")
      @project = File.join(@projects, "shelf")
    end

    def sql(url : String, statement : String) : String
      uri = URI.parse(url)
      query = HTTP::Params.parse(uri.query || "")
      pg_env = environment({"PGPASSWORD" => URI.decode(uri.password || "")})
      command([@psql, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", query["host"], "-p", query["port"]? || "5432", "-U", URI.decode(uri.user.not_nil!), "-d", uri.path.lchop('/')], environment: pg_env, input: statement, echo: false, timeout: 15.seconds).stdout.strip
    end

    def schema(body : String) : Nil
      File.write(File.join(@project, "app/models/book.cr"), "struct Book < SugarORM::Schema\n  schema \"books\" do\n#{body.lines.map { |line| "    #{line}\n" }.join}  end\nend\n")
    end

    def migrations : Array(String)
      Dir.children(File.join(@project, "db/migrations")).reject(&.starts_with?('.')).sort
    end

    def diff(name : String, flags : Array(String) = [] of String) : Array(String)
      before = migrations
      result = command([@frappe, "db", "diff", "--name", name] + flags, chdir: @project, timeout: COMPILE)
      added = migrations - before
      assert!(result.stdout.lines.select(&.starts_with?("Wrote ")).size == added.size, result.stdout)
      added.map { |file| File.read(File.join(@project, "db/migrations", file)).tap { |source| assert!(file.matches?(/\A\d{14}_#{name}(_concurrently)?\.cr\z/), file); assert!(source.includes?("SugarORM::Migration.new"), source) } }
    end

    def refused(args : Array(String), expected : Array(String)) : Nil
      before = migrations
      result = attempt([@frappe] + args, chdir: @project, timeout: COMPILE)
      output = result.stdout + result.stderr
      assert!(!result.success?, "#{args.join(" ")} must fail:\n#{output}")
      expected.each { |text| assert!(output.includes?(text), "missing #{text.inspect} in:\n#{output}") }
      assert!(migrations == before, "a refused command left migration files: #{migrations - before}")
    end

    def branches(id : String) : Array(JSON::Any)
      rpc("GET", "/v1/sites/#{id}/branches")["branches"].as_a
    end

    def execute : Nil
      puts "Schema diff fixture: #{@root}"
      failed = true
      begin
        start
        command([@frappe, "new", "shelf"], chdir: @projects)
        values = local_values(@project)
        id = site("shelf")["id"].as_s
        migration_url, runtime_url = values["MIGRATION_DATABASE_URL"], values["DATABASE_URL"]

        schema(<<-CRYSTAL)
          field id : Int64, primary: true
          field title : String
          timestamps
          CRYSTAL
        created = diff("create_books")
        assert!(created.size == 1 && created[0].includes?("    CREATE TABLE \"books\" (\n      \"id\" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\n      \"title\" text NOT NULL,"), created.inspect)
        migrated = command([@frappe, "migrate"], chdir: @project, timeout: COMPILE).stdout
        assert!(migrated.includes?("Applied 1 migrations.") && migrated.includes?("The database matches the declared schema."), migrated)
        assert!(sql(runtime_url, "SELECT count(*) FROM books") == "0")
        unchanged = command([@frappe, "db", "diff", "--name", "nothing"], chdir: @project, timeout: COMPILE).stdout
        assert!(unchanged.includes?("already matches the declared schema") && unchanged.includes?("ignored table caramel_migrations"), unchanged)
        assert!(branches(id).empty?, "scratch branches remain: #{branches(id)}")
        puts "PASS: frappe db diff wrote a CREATE TABLE migration from the schema, frappe migrate applied it, and a second diff found nothing"

        sql(migration_url, "INSERT INTO books (title) VALUES ('Dune')")
        schema(<<-CRYSTAL)
          field id : Int64, primary: true
          field name : String, renamed_from: :title
          field pages : Int32 = 0
          timestamps
          index :pages
          CRYSTAL
        evolved = diff("evolve_books")
        assert!(evolved.size == 2, evolved.inspect)
        assert!(evolved[0].includes?(%(-- caramel:allow-rename books.title\n    ALTER TABLE "books" RENAME COLUMN "title" TO "name")) && evolved[0].includes?(%(ALTER TABLE "books" ADD COLUMN "pages" integer NOT NULL DEFAULT 0)), evolved[0])
        assert!(evolved[1].includes?(%(CREATE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_pages" ON "books" ("pages"))) && !evolved[1].includes?("ALTER TABLE"), evolved[1])
        migrated = command([@frappe, "migrate"], chdir: @project, timeout: COMPILE).stdout
        assert!(migrated.includes?("Applied 2 migrations."), migrated)
        assert!(sql(runtime_url, "SELECT name || ':' || pages FROM books") == "Dune:0")
        assert!(sql(runtime_url, "SELECT indisvalid FROM pg_index WHERE indexrelid = 'index_books_on_pages'::regclass") == "t")
        puts "PASS: a default-bearing field, a renamed_from rename (data kept) and an index diffed into a transactional and a separate CONCURRENTLY migration"

        sql(migration_url, "DELETE FROM books")
        schema(<<-CRYSTAL)
          field id : Int64, primary: true
          field name : String, renamed_from: :title
          field pages : Int32 = 0
          field isbn : String
          timestamps
          index :pages
          CRYSTAL
        refused(%w(db diff --name add_isbn), ["HALT books.isbn: NOT NULL column without a default", "Remediation: give the field a default", "--dev-override"])
        overridden = diff("add_isbn", ["--dev-override"])
        assert!(overridden.size == 1 && overridden[0].includes?(%(ALTER TABLE "books" ADD COLUMN "isbn" text NOT NULL\n)), overridden.inspect)
        refused(%w(migrate), ["LINT not-null-default: ADD COLUMN isbn NOT NULL without a DEFAULT", "--dev-override downgrades"])
        app = File.join(@project, ".caramel/application")
        app_env = environment(values.merge({"CARAMEL_ENV" => "development", "CARAMEL_EXPECTED_DATABASE_URL" => runtime_url}))
        linted = attempt([app, "lint"], chdir: @project, environment: app_env)
        assert!(!linted.success? && linted.stderr.includes?("LINT not-null-default") && sql(runtime_url, "SELECT count(*) FROM caramel_migrations") == "3", linted.stdout + linted.stderr)
        linted = command([app, "lint", "--dev-override"], chdir: @project, environment: app_env, echo: false)
        assert!(linted.stdout.includes?("Pending migrations pass the zero-lock linter.") && linted.stderr.includes?("WARN (--dev-override) LINT not-null-default"), linted.stdout + linted.stderr)
        applied = command([@frappe, "migrate", "--dev-override"], chdir: @project, timeout: COMPILE)
        assert!(applied.stdout.includes?("Applied 1 migrations.") && applied.stderr.includes?("WARN (--dev-override) LINT not-null-default"), applied.stdout + applied.stderr)
        puts "PASS: a NOT NULL field without a default halts the diff; --dev-override derives it, and lint and frappe migrate accept it only with --dev-override"

        schema(<<-CRYSTAL)
          field id : Int64, primary: true
          field name : String, renamed_from: :title
          field isbn : String
          timestamps
          CRYSTAL
        refused(%w(db diff --name drop_pages), ["HALT books.pages: column exists in the database but no field declares it", "drop_column :pages"])
        schema(<<-CRYSTAL)
          field id : Int64, primary: true
          field name : String, renamed_from: :title
          field isbn : String
          timestamps
          drop_column :pages
          CRYSTAL
        dropped = diff("drop_pages")
        assert!(dropped.size == 1 && dropped[0].includes?(%(-- caramel:allow-drop books.pages\n    ALTER TABLE "books" DROP COLUMN "pages")) && !dropped[0].includes?("DROP INDEX"), dropped.inspect)
        migrated = command([@frappe, "migrate"], chdir: @project, timeout: COMPILE).stdout
        assert!(migrated.includes?("Applied 1 migrations.") && migrated.includes?("The database matches the declared schema."), migrated)
        assert!(sql(runtime_url, "SELECT count(*) FROM pg_attribute WHERE attrelid = 'books'::regclass AND attname = 'pages' AND NOT attisdropped") == "0")
        puts "PASS: an undeclared column halts the diff; drop_column derives an annotated DROP COLUMN that passes the linter"

        sql(migration_url, "ALTER TABLE books ADD COLUMN sneaky text")
        drift = command([@frappe, "migrate"], chdir: @project, timeout: COMPILE)
        assert!(drift.stdout.includes?("Applied 0 migrations."), drift.stdout)
        assert!(drift.stderr.includes?("WARNING: schema drift") && drift.stderr.includes?("HALT books.sneaky") && drift.stderr.includes?("Remediation: run frappe db diff"), drift.stdout + drift.stderr)
        assert!(branches(id).empty?, "scratch branches remain: #{branches(id)}")
        assert!(sql(runtime_url, "SELECT datallowconn FROM pg_database WHERE datname = current_database()") == "t")
        puts "PASS: frappe migrate reports schema drift read-only as a warning, and every scratch branch was dropped"
        failed = false
      ensure
        finish(failed)
      end
    end
  end
end

begin
  Caramel::Checks::SchemaDiff.new.execute
rescue ex
  STDERR.puts ex.message
  exit 1
end
