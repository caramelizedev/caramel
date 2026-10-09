require "./support/latte_fixture"
require "../../src/caramel/cold_brew/migrations"
require "uri"
require "http/params"

module Caramel::Checks
  # End-to-end branch-and-diff: a generated project evolves a SugarORM schema
  # through frappe db diff and frappe migrate against a disposable Latte.
  class SchemaDiff < LatteFixture
    COMPILE      = 300.seconds
    MATCHED      = "The database matches the declared schema."
    DOWNGRADED   = "WARN (--dev-override) LINT not-null-default"
    CODEC_FIELDS = [
      "field price : Price?, codec: PriceCodec",
      "field extra : Extra?, codec: SugarORM::JSONB(Extra)",
    ]
    NOT_NULL = /^ERR LINT_NOT_NULL_DEFAULT at db\/migrations\/\d{14}_add_isbn\.cr$/m

    def initialize
      toolchain = Checks.toolchain_root
      super("caramel-schema-diff-")
      @psql = File.join(toolchain, "data/installs/conda-postgresql/18.6/bin/psql")
      @project = File.join(@projects, "shelf")
    end

    def sql(url : String, statement : String) : String
      uri = URI.parse(url)
      query = HTTP::Params.parse(uri.query || "")
      pg_env = environment({"PGPASSWORD" => URI.decode(uri.password || "")})
      psql = [@psql, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1",
              "-h", query["host"], "-p", query["port"]? || "5432",
              "-U", URI.decode(uri.user.not_nil!), "-d", uri.path.lchop('/')]
      result = command(psql,
        environment: pg_env, input: statement, echo: false, timeout: 15.seconds)
      result.stdout.strip
    end

    # Writes the Book model with *body* and its two codec fields inside its
    # schema block, after the codecs they name.
    def schema(body : String) : Nil
      fields = (body.lines + CODEC_FIELDS).map { |line| "    #{line}\n" }.join
      File.write(File.join(@project, "app/models/book.cr"), <<-CR)
        record Price, text : String

        module PriceCodec
          def self.sql_type : String
            "numeric(20,8)"
          end

          def self.encode(value : Price) : String
            value.text
          end

          def self.decode(text : String) : Price
            Price.new(text)
          end
        end

        record Extra, note : String do
          include JSON::Serializable
        end

        struct Book < SugarORM::Schema
          schema "books" do
        #{fields}  end
        end

        CR
    end

    def migrations : Array(String)
      Dir.children(File.join(@project, "db/migrations")).reject(&.starts_with?('.')).sort!
    end

    def diff(name : String, flags : Array(String) = [] of String) : Array(String)
      before = migrations
      argv = [@frappe, "db", "diff", "--name", name] + flags
      result = command(argv, chdir: @project, timeout: COMPILE)
      added = migrations - before
      assert!(result.stdout.lines.count(&.starts_with?("Wrote ")) == added.size, result.stdout)
      added.map do |file|
        source = File.read(File.join(@project, "db/migrations", file))
        assert!(file.matches?(/\A\d{14}_#{name}(_concurrently)?\.cr\z/), file)
        assert!(source.includes?("SugarORM::Migration.new"), source)
        source
      end
    end

    def refused(args : Array(String), expected : Array(String)) : String
      before = migrations
      result = attempt([@frappe] + args, chdir: @project, timeout: COMPILE)
      output = result.stdout + result.stderr
      assert!(result.status.exit_code == 1, "#{args.join(" ")} must exit 1:\n#{output}")
      expected.each do |text|
        assert!(output.includes?(text), "missing #{text.inspect} in:\n#{output}")
      end
      after = migrations
      assert!(after == before, "a refused command left migration files: #{after - before}")
      output
    end

    def branches(id : String) : Array(JSON::Any)
      rpc("GET", "/v1/sites/#{id}/branches")["branches"].as_a
    end

    # Asserts that *output* includes every one of *parts*.
    private def assert_includes!(output : String, *parts : String) : Nil
      assert!(parts.all? { |part| output.includes?(part) }, output)
    end

    def execute : Nil
      puts "Schema diff fixture: #{@root}"
      # ameba:disable Lint/UselessAssign -- read by the ensure below
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
        create_table = <<-SQL
              CREATE TABLE "books" (
                "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                "title" text NOT NULL,
          SQL
        assert!(created.size == 1 && created[0].includes?(create_table), created.inspect)
        codecs = [%("price" numeric(20,8)), %("extra" jsonb)]
        assert!(codecs.all? { |column| created[0].includes?(column) }, created.inspect)
        migrated = command([@frappe, "migrate"], chdir: @project, timeout: COMPILE).stdout
        # frappe new applied Caramel's three Cold Brew migrations; this applies
        # the application's first.
        assert_includes!(migrated, "Applied 1 migrations.", MATCHED)
        assert!(sql(runtime_url, "SELECT count(*) FROM books") == "0")
        nothing = [@frappe, "db", "diff", "--name", "nothing"]
        unchanged = command(nothing, chdir: @project, timeout: COMPILE).stdout
        assert_includes!(unchanged,
          "already matches the declared schema",
          "ignored table caramel_migrations",
          "ignored table caramel_jobs (owned by Caramel)")
        assert!(branches(id).empty?, "scratch branches remain: #{branches(id)}")
        puts "PASS: frappe db diff wrote a CREATE TABLE migration from the schema, " \
             "frappe migrate applied it, and a second diff found nothing " \
             "(codec fields became numeric(20,8) and jsonb columns)"

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
        rename = <<-SQL
          -- caramel:allow-rename books.title
              ALTER TABLE "books" RENAME COLUMN "title" TO "name"
          SQL
        add_pages = %(ALTER TABLE "books" ADD COLUMN "pages" integer NOT NULL DEFAULT 0)
        assert_includes!(evolved[0], rename, add_pages)
        index = %(CREATE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_pages" ) \
                %(ON "books" ("pages"))
        separate = evolved[1].includes?(index) && !evolved[1].includes?("ALTER TABLE")
        assert!(separate, evolved[1])
        migrated = command([@frappe, "migrate"], chdir: @project, timeout: COMPILE).stdout
        assert!(migrated.includes?("Applied 2 migrations."), migrated)
        assert!(sql(runtime_url, "SELECT name || ':' || pages FROM books") == "Dune:0")
        validity = "SELECT indisvalid FROM pg_index " \
                   "WHERE indexrelid = 'index_books_on_pages'::regclass"
        assert!(sql(runtime_url, validity) == "t")
        puts "PASS: a default-bearing field, a renamed_from rename (data kept) " \
             "and an index diffed into a transactional " \
             "and a separate CONCURRENTLY migration"

        sql(migration_url, "DELETE FROM books")
        schema(<<-CRYSTAL)
          field id : Int64, primary: true
          field name : String, renamed_from: :title
          field pages : Int32 = 0
          field isbn : String
          timestamps
          index :pages
          CRYSTAL
        # Piped output is agent mode: halts and lint refusals print as MRDP.
        refused(%w[db diff --name add_isbn], [
          "ERR DIFF_HALT at books.isbn\nMSG: NOT NULL column without a default",
          "\nFIX: give the field a default",
        ])
        overridden = diff("add_isbn", ["--dev-override"])
        add_isbn = %(ALTER TABLE "books" ADD COLUMN "isbn" text NOT NULL\n)
        derived = overridden.size == 1 && overridden[0].includes?(add_isbn)
        assert!(derived, overridden.inspect)
        lint = refused(%w[migrate], [
          "\nMSG: ADD COLUMN isbn NOT NULL without a DEFAULT",
          "\nFIX: give the column a DEFAULT",
        ])
        assert!(lint.matches?(NOT_NULL), lint)
        refused(%w[migrate --human], [
          "LINT not-null-default: ADD COLUMN isbn NOT NULL without a DEFAULT",
          "--dev-override downgrades",
        ])
        app = File.join(@project, ".caramel/application")
        development = {
          "CARAMEL_ENV"                   => "development",
          "CARAMEL_EXPECTED_DATABASE_URL" => runtime_url,
        }
        app_env = environment(values.merge(development))
        linted = attempt([app, "lint"], chdir: @project, environment: app_env)
        linted_output = linted.stdout + linted.stderr
        blocked = !linted.success? && linted.stderr.includes?("LINT not-null-default")
        assert!(blocked, linted_output)
        # The framework's migrations and the three the project has applied so far.
        recorded = sql(runtime_url, "SELECT count(*) FROM caramel_migrations")
        expected = Caramel::ColdBrew::MIGRATIONS.size + 3
        assert!(recorded == expected.to_s, "#{recorded} migrations recorded\n#{linted_output}")
        linted = command([app, "lint", "--dev-override"],
          chdir: @project, environment: app_env, echo: false)
        passed = linted.stdout.includes?("Pending migrations pass the zero-lock linter.")
        downgraded = linted.stderr.includes?(DOWNGRADED)
        assert!(passed && downgraded, linted.stdout + linted.stderr)
        applied = command([@frappe, "migrate", "--dev-override"],
          chdir: @project, timeout: COMPILE)
        applied_one = applied.stdout.includes?("Applied 1 migrations.")
        warned = applied.stderr.includes?(DOWNGRADED)
        assert!(applied_one && warned, applied.stdout + applied.stderr)
        puts "PASS: a NOT NULL field without a default halts the diff " \
             "(MRDP ERR DIFF_HALT when piped); --dev-override derives it, " \
             "and lint and frappe migrate (MRDP ERR LINT_NOT_NULL_DEFAULT " \
             "at its migration file, human text with --human) " \
             "accept it only with --dev-override"

        schema(<<-CRYSTAL)
          field id : Int64, primary: true
          field name : String, renamed_from: :title
          field isbn : String
          timestamps
          CRYSTAL
        refused(%w[db diff --name drop_pages --human], [
          "HALT books.pages: column exists in the database but no field declares it",
          "drop_column :pages",
        ])
        schema(<<-CRYSTAL)
          field id : Int64, primary: true
          field name : String, renamed_from: :title
          field isbn : String
          timestamps
          drop_column :pages
          CRYSTAL
        dropped = diff("drop_pages")
        drop = <<-SQL
          -- caramel:allow-drop books.pages
              ALTER TABLE "books" DROP COLUMN "pages"
          SQL
        annotated = dropped.size == 1 && dropped[0].includes?(drop)
        assert!(annotated && !dropped[0].includes?("DROP INDEX"), dropped.inspect)
        migrated = command([@frappe, "migrate"], chdir: @project, timeout: COMPILE).stdout
        assert_includes!(migrated, "Applied 1 migrations.", MATCHED)
        columns = "SELECT count(*) FROM pg_attribute " \
                  "WHERE attrelid = 'books'::regclass " \
                  "AND attname = 'pages' AND NOT attisdropped"
        assert!(sql(runtime_url, columns) == "0")
        puts "PASS: an undeclared column halts the diff; " \
             "drop_column derives an annotated DROP COLUMN that passes the linter"

        sql(migration_url, "ALTER TABLE books ADD COLUMN sneaky text")
        drift = command([@frappe, "migrate"], chdir: @project, timeout: COMPILE)
        assert!(drift.stdout.includes?("Applied 0 migrations."), drift.stdout)
        warnings = ["WARNING: schema drift", "HALT books.sneaky",
                    "Remediation: run frappe db diff"]
        warned = warnings.all? { |text| drift.stderr.includes?(text) }
        assert!(warned, drift.stdout + drift.stderr)
        assert!(branches(id).empty?, "scratch branches remain: #{branches(id)}")
        allowed = "SELECT datallowconn FROM pg_database " \
                  "WHERE datname = current_database()"
        assert!(sql(runtime_url, allowed) == "t")
        puts "PASS: frappe migrate reports schema drift read-only as a warning, " \
             "and every scratch branch was dropped"
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
