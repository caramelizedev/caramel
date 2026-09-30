require "./support/latte_fixture"
require "../../src/frappe/commands"
require "uri"
require "http/params"

module Caramel::Checks
  class FrappeProject < LatteFixture
    getter project : String

    MATCHED         = "The database matches the declared schema."
    RESOURCE_ROUTES = "    # Frappé resource routes"

    # What Corretto prints when corretto_probe_spec.cr's line 25 leaks DDL.
    CATALOG_RESET = Regex.new("corretto_probe_spec\\.cr:25 " \
                              "changed the database catalog outside its transaction; " \
                              "worker [12] was reset")

    def initialize
      toolchain = Checks.toolchain_root
      super("caramel-frappe-")
      @psql = File.join(toolchain, "data/installs/conda-postgresql/18.6/bin/psql")
      @project = File.join(@projects, "bookshelf")
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

    # Asserts that *result* exited 1 after printing exactly *expected*.
    private def assert_reported!(result : Caramel::Latte::ProcessResult,
                                 expected : String) : Nil
      reported = result.status.exit_code == 1 && result.stdout == expected
      assert!(reported, result.stdout + result.stderr)
    end

    def execute(args : Array(String)) : Nil
      puts "Frappé fixture: #{@root}"
      # ameba:disable Lint/UselessAssign -- read by the ensure below
      failed = true
      begin
        start
        command([@frappe, "new", "bookshelf"], chdir: @projects)
        values = local_values(@project)
        assert!(File.info(File.join(@project, ".env")).permissions.value == 0o600)
        keys = %w[
          DATABASE_URL MIGRATION_DATABASE_URL
          SPEC_DATABASE_URL SPEC_MIGRATION_DATABASE_URL
        ]
        urls = keys.map { |key| values[key] }
        assert!(urls.uniq.size == 4)
        make = [@frappe, "make", "resource"]
        person = %w[
          Person name:string age:int32 total:int64 active:bool rating:float64?
          joined_at:time? --plural=people
        ]
        link = %w[
          Link title:string? original_url:string:unique
          short_code:string:server:unique click_count:int64:server
        ]
        command(make + %w[Book title:string author:string], chdir: @project)
        command(make + person, chdir: @project)
        command(make + link, chdir: @project)
        routes = command([@frappe, "routes"], chdir: @project, echo: false).stdout
        print routes
        show = %w[GET /books/:id App::Books::Show id:Int64(min=1)]
        update = %w[
          PATCH /people/:id App::People::Update id:Int64(min=1)
          name:String age:Int32 total:Int64 active:Bool rating:Float64? joined_at:Time?
        ]
        create = %w[POST /links App::Links::Create title:String? original_url:String]
        [show, update, create].each do |route|
          assert!(routes.lines.any? { |line| line.split == route }, routes)
        end
        agent_tooling
        migrated = command([@frappe, "migrate"], chdir: @project)
        assert!(migrated.stdout.includes?(MATCHED), migrated.stdout)
        # The generated create_* migrations must be exactly what the differ
        # derives, so diffing the migrated database finds nothing to write.
        drift_probe = [@frappe, "db", "diff", "--name", "drift_probe"]
        probe = command(drift_probe, chdir: @project, timeout: 300.seconds)
        nothing = "already matches the declared schema; no migration was written"
        assert!(probe.stdout.includes?(nothing), probe.stdout)
        assert!(Dir.glob(File.join(@project, "db/migrations/*drift_probe*")).empty?)
        puts "PASS: generated SugarORM resources migrate without drift, " \
             "and frappe db diff --name drift_probe derives nothing"
        sentinel = "CREATE TABLE dev_sentinel (value text NOT NULL); " \
                   "INSERT INTO dev_sentinel VALUES ('keep');"
        sql(values["MIGRATION_DATABASE_URL"], sentinel)
        corretto(values)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")
        env_path = File.join(@project, ".env")
        original_env = File.read(env_path)
        spec_url = "SPEC_DATABASE_URL=#{values["SPEC_DATABASE_URL"].to_json}"
        development_url = "SPEC_DATABASE_URL=#{values["DATABASE_URL"].to_json}"
        changed = original_env.sub(spec_url, development_url)
        assert!(changed != original_env)
        File.write(env_path, changed)
        refused = attempt([@frappe, "corretto"], chdir: @project, timeout: 30.seconds)
        assert!(!refused.success? && refused.stderr.includes?("specs refused"), refused.stderr)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")
        File.write(env_path, original_env)
        command([@frappe, "setup"], chdir: @project)
        assert!(local_values(@project)["APP_SECRET"] == values["APP_SECRET"])
        doctor = attempt([@frappe, "doctor"], chdir: @project, timeout: 35.seconds)
        assert!(doctor.stdout.includes?("OK    Managed Crystal compiler"), doctor.stdout)
        assert!(doctor.stdout.includes?("OK    Locked dependencies"), doctor.stdout)
        assert!(File.read(env_path) == original_env)

        clone = File.join(@projects, "bookshelf-clone")
        Dir.mkdir(clone, 0o700)
        Dir.children(@project).each do |entry|
          next if %w[lib .caramel .env].includes?(entry)
          copy = ["/bin/cp", "-R", File.join(@project, entry), File.join(clone, entry)]
          command(copy, echo: false)
        end
        manifest = File.join(clone, "config/environment.yml")
        File.write(manifest, File.read(manifest).sub("name: bookshelf", "name: bookshelf-clone"))
        readme = File.join(clone, "README.md")
        File.write(readme, File.read(readme) + "\nAn application-specific note.\n")
        command([@frappe, "setup"], chdir: clone)
        clone_values = local_values(clone)
        assert!(clone_values["APP_SECRET"] != values["APP_SECRET"])
        assert!(clone_values["DATABASE_URL"] != values["DATABASE_URL"])
        assert!(File.read(readme).ends_with?("An application-specific note.\n"))
        command([@frappe, "corretto"], chdir: clone, timeout: 600.seconds)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")

        injected = File.join(@root, "package-with-failed-installer")
        Dir.mkdir(injected)
        %w[src templates vendor].each do |folder|
          copy = ["/bin/cp", "-R", File.join(@repo, folder), File.join(injected, folder)]
          command(copy, echo: false)
        end
        %w[shard.yml shard.lock LICENSE THIRD_PARTY_NOTICES.md].each do |name|
          File.copy(File.join(@repo, name), File.join(injected, name))
        end
        Dir.mkdir(File.join(injected, "scripts"))
        failed_shards = File.join(injected, "scripts/shards")
        File.write(failed_shards, "#!/bin/sh\nexit 67\n")
        File.chmod(failed_shards, 0o700)
        framework = environment({"CARAMEL_FRAMEWORK_ROOT" => injected})
        interrupted = attempt([@frappe, "new", "resumed"],
          chdir: @projects, timeout: 40.seconds, environment: framework)
        resumable = interrupted.stderr.includes?("frappe setup to resume")
        assert!(!interrupted.success? && resumable, interrupted.stderr)
        resumed = File.join(@projects, "resumed")
        resume_readme = File.join(resumed, "README.md")
        File.write(resume_readme, File.read(resume_readme) + "\nPreserve this edit during setup.\n")
        command([@frappe, "setup"], chdir: resumed)
        assert!(File.read(resume_readme).ends_with?("Preserve this edit during setup.\n"))
        dump = command([@frappe, "db", "dump"], chdir: @project, echo: false)
        backup = dump.stdout.lines.last.strip.split(": ", 2).last
        backups = File.join(@state, "backups") + "/"
        private_backup = backup.starts_with?(backups) &&
                         File.info(backup).permissions.value == 0o600
        assert!(private_backup, dump.stdout)
        sql(values["MIGRATION_DATABASE_URL"], "DELETE FROM dev_sentinel")
        restored = command([@frappe, "db", "restore", backup], chdir: @project, echo: false)
        saved = restored.stdout.includes?("Saved the current development database to")
        assert!(saved, restored.stdout)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")
        missing_log = attempt([@frappe, "logs"], chdir: @project)
        guided = missing_log.stderr.includes?("No app log for bookshelf yet")
        assert!(missing_log.status.exit_code == 1 && guided, missing_log.stderr)

        resumed_id = site("resumed")["id"].as_s
        resumed_url = local_values(resumed)["DATABASE_URL"]
        removed = command([@frappe, "sites", "remove", "resumed"], echo: false)
        assert!(removed.stdout.includes?("Removed resumed"), removed.stdout)
        sites = rpc("GET", "/v1/sites")["sites"].as_a
        assert!(sites.none? { |entry| entry["name"].as_s == "resumed" })
        assert!(File.exists?(File.join(@state, "secrets", "site-#{resumed_id}.json")))
        command([@frappe, "setup"], chdir: resumed, echo: false)
        same_site = site("resumed")["id"].as_s == resumed_id
        assert!(same_site && local_values(resumed)["DATABASE_URL"] == resumed_url)
        puts "PASS: frappe db dump/restore with safety dump, missing-log guidance, " \
             "and site removal with retained data and re-registration"
        git_source

        Dev.new(self, clone).check if args.includes?("--dev")
        edit_only = args.includes?("--edit-benchmark")
        if args.includes?("--benchmark") || edit_only
          Benchmark.new(self, edit_only: edit_only).check
        end

        serve(@project, "bookshelf", values)
        port = @ports[2]
        curl = ["/usr/bin/curl", "--fail", "--silent", "--show-error",
                "--max-time", "5", "--noproxy", "*", "--cacert", certificate,
                "--resolve", "bookshelf.caramel:#{port}:127.0.0.1",
                "-H", "Host: bookshelf.caramel", "https://bookshelf.caramel:#{port}/"]
        page = command(curl, echo: false)
        welcome = page.stdout.includes?("A little less setup.")
        assert!(welcome && page.stdout.includes?("/assets/htmx-4.0.0.min.js"))
        puts "PASS: real frappe new/setup/migrate/routes/corretto, clone secrets, " \
             "failed-dependency recovery, source preservation, " \
             "spec refusal for development URL, retained development data, " \
             "and generated native app over CA-verified named HTTPS"
        failed = false
      ensure
        finish(failed)
      end
    end

    # ADR 0016: a generated application depends on a tagged Caramel release by
    # git. A repository of this working tree, tagged as this release, stands in
    # for github.com/caramelizedev/caramel.
    def git_source : Nil
      url = "file://#{Checks.tagged_repository(File.join(@root, "caramel.git"), Caramel::VERSION)}"
      repository = environment({"CARAMEL_REPOSITORY" => url})
      command([@frappe, "new", "tagged"], chdir: @projects, environment: repository)
      tagged = File.join(@projects, "tagged")
      dependency = <<-YAML
          caramel:
            git: #{url.to_json}
            version: "~> #{Caramel::VERSION}"\n
        YAML
      assert!(File.read(File.join(tagged, "shard.yml")).ends_with?(dependency))
      locked = <<-YAML
          caramel:
            git: #{url.to_json}
            version: #{Caramel::VERSION}\n
        YAML
      assert!(File.read(File.join(tagged, "shard.lock")).includes?(locked))
      library = File.join(tagged, "lib/caramel")
      checkout = File.info(library, follow_symlinks: false).directory? &&
                 File.file?(File.join(library, "src/caramel/command_line.cr"))
      assert!(checkout, "lib/caramel is not the tagged release")
      checked = command([@frappe, "check"], chdir: tagged, echo: false)
      assert!(checked.stdout.starts_with?("OK check "), checked.stdout)
      puts "PASS: frappe new against a repository tagged v#{Caramel::VERSION} " \
           "resolves the framework by git, migrates and type-checks"
    end

    # RFC-0005 agent tooling on the generated project: the stateless manifest,
    # strict usage errors, the routes filter, Tier-1 `frappe check` with MRDP
    # whose PATCH lines are applied mechanically until the check passes, the
    # human typography, `frappe expand` and database branches.
    def agent_tooling : Nil
      absent = environment({"CARAMEL_HOME" => File.join(@root, "absent-latte")})
      listing = command([@frappe, "agent-manifest"],
        chdir: "/", environment: absent, echo: false)
      manifest = listing.stdout.lines
      assert!(manifest.first? == "CARAMEL CLI INTERFACE (STRICT TOKENS)", manifest.first?.to_s)
      assert!(manifest[1]? == "VERSION: #{Caramel::VERSION}", manifest[1]?.to_s)
      Caramel::Frappe::Commands::TABLE.each do |entry|
        line = "frappe #{entry.syntax}  # #{entry.summary}"
        assert!(manifest.includes?(line), "manifest lacks frappe #{entry.syntax}")
      end
      syntaxes = [
        "check [--agent|--human]", "lint [--agent|--human]", "format", "routes [FILTER]",
        "db branch create NAME", "db diff --name NAME", "corretto [SPEC_PATHS...]",
        "expand FILE:LINE:COL",
      ]
      syntaxes.each do |syntax|
        offered = manifest.any?(&.starts_with?("frappe #{syntax}"))
        assert!(offered, "manifest lacks frappe #{syntax}")
      end
      patch_syntax = %(PATCH: INSERT "<text>" AT <line>:<col>)
      assert!(manifest.any?(&.starts_with?(patch_syntax)), manifest.join("\n"))
      unknown = attempt([@frappe, "routes", "--verbose"], chdir: @project)
      usage = <<-MRDP
        ERR USAGE at frappe routes
        MSG: unknown option --verbose
        SYNTAX: frappe routes [FILTER]\n
        MRDP
      assert!(unknown.status.exit_code == 1 && unknown.stderr == usage, unknown.stderr)
      typo = attempt([@frappe, "chek", "--human"], chdir: @project)
      suggestion = "Usage: frappe check [--agent|--human]\nDid you mean check?"
      suggested = typo.stderr.includes?(suggestion)
      assert!(typo.status.exit_code == 1 && suggested, typo.stderr)
      puts "PASS: frappe agent-manifest lists every command without Latte, " \
           "and unknown input exits 1 with the exact syntax and a suggestion"

      people = command([@frappe, "routes", "people"], chdir: @project, echo: false).stdout.lines
      assert!(people.size == 7, people.join("\n"))
      scoped = people.all? do |line|
        fields = line.split
        fields[1].starts_with?("/people") && fields[2].starts_with?("App::People::")
      end
      assert!(scoped, people.join("\n"))
      patches = command([@frappe, "routes", "patch"], chdir: @project, echo: false).stdout.lines
      expected = [%w[PATCH /books/:id], %w[PATCH /people/:id], %w[PATCH /links/:id]]
      assert!(patches.map { |line| line.split[0, 2] } == expected, patches.join("\n"))
      unmatched = command([@frappe, "routes", "no-such-route"],
        chdir: @project, echo: false)
      assert!(unmatched.stdout.empty?)
      puts "PASS: frappe routes FILTER keeps routes " \
           "whose method, path or action contains it, ignoring case"

      assert!(File.file?(File.join(@project, ".ameba.yml")),
        "the generated application lacks its rule set, .ameba.yml")
      linted = command([@frappe, "lint"], chdir: @project, echo: false)
      assert!(linted.stdout.matches?(/\AOK lint \d+ files\n\z/), linted.stdout)
      noun = File.join(@project, "app/models/invitation_service.cr")
      File.write(noun, "module App\n  class  InvitationService\n  end\nend\n")
      flagged = attempt([@frappe, "lint", "--agent"], chdir: @project)
      # A backslash at a line's end joins it to the next line.
      assert_reported!(flagged, <<-MRDP)
        ERR LINT_LINT_FORMATTING at app/models/invitation_service.cr:1:1
        MSG: Use built-in formatter to format this source (Lint/Formatting)
        FIX: frappe format
        ERR LINT_CARAMEL_SERVICE_NOUN at app/models/invitation_service.cr:2:10
        MSG: `InvitationService` is a service noun; put the verb on its subject instead \
        (RFC-0008 §2.1), e.g. a method on the model, a changeset or a job \
        (Caramel/ServiceNoun)\n
        MRDP
      command([@frappe, "format"], chdir: @project, echo: false)
      formatted = "module App\n  class InvitationService\n  end\nend\n"
      assert!(File.read(noun) == formatted, File.read(noun))
      File.delete(noun)
      relinted = command([@frappe, "lint"], chdir: @project, echo: false)
      assert!(relinted.stdout.starts_with?("OK lint "))
      puts "PASS: the generated application and its resources pass frappe lint; " \
           "a planted service noun yields ERR LINT_CARAMEL_SERVICE_NOUN, " \
           "and frappe format fixes its layout"

      clean = command([@frappe, "check"], chdir: @project, echo: false)
      assert!(clean.stdout.matches?(/\AOK check \d+ files\n\z/), clean.stdout)
      human_clean = command([@frappe, "check", "--human"], chdir: @project, echo: false)
      assert!(human_clean.stdout == "✓ Type check passed\n")

      action = File.join(@project, "app/actions/shelves/show.cr")
      Dir.mkdir_p(File.dirname(action))
      File.write(action, SHELF_ACTION)
      routes = File.join(@project, "config/routes.cr")
      original_routes = File.read(routes)
      shelf_route = %(    get "/shelves/:id", App::Shelves::Show\n) \
                    %(    # Frappé resource routes)
      File.write(routes, original_routes.sub(RESOURCE_ROUTES, shelf_route))
      mismatch = attempt([@frappe, "check"], chdir: @project)
      assert_reported!(mismatch, <<-MRDP)
        ERR CONTRACT_MISMATCH:422 at app/actions/shelves/show.cr:3:5
        NODE: RequestContract
        MISSING: id:Int64
        PATCH: INSERT "field id : Int64" AT 4:7\n
        MRDP
      apply(mismatch.stdout)
      repaired = command([@frappe, "check"], chdir: @project, echo: false)
      assert!(repaired.stdout.starts_with?("OK check "), repaired.stdout)
      puts "PASS: a planted route-contract mismatch yields MRDP with a PATCH, " \
           "and applying the PATCH line mechanically makes frappe check pass"

      model = File.join(@project, "app/models/shelf.cr")
      File.write(model, SHELF_MODELS)
      titles = <<-CRYSTAL
        titles = App::Shelf.query.find!(contract.id).volumes.map(&.title)
              page "Shelf", titles.join(", ")
        CRYSTAL
      shelf_page = %(page "Shelf", "Shelf \#{contract.id}")
      File.write(action, File.read(action).sub(shelf_page, titles))
      n_plus_one = attempt([@frappe, "check", "--agent"], chdir: @project)
      assert_reported!(n_plus_one, <<-MRDP)
        ERR N_PLUS_ONE at app/actions/shelves/show.cr:9:52
        MSG: Association 'volumes' of App::Shelf was not preloaded.
        PATCH: INSERT ".preload(:volumes)" AFTER 9:31\n
        MRDP
      human = attempt([@frappe, "check", "--human"], chdir: @project)
      assert!(human.status.exit_code == 1 && !human.stdout.includes?("\e["), human.stdout)
      boxed = [
        "  ╭─[ app/actions/shelves/show.cr:9 ]\n",
        "  │  9 │       titles = App::Shelf.query.find!(contract.id).volumes.map(&.title)\n",
        "  │    │ #{" " * 51}^^^^^^^ " \
        "Association 'volumes' of App::Shelf was not preloaded.\n",
        "  ╰─ Accessing un-preloaded relationships triggers runtime N+1 queries.\n",
        "     Remediation:\n" \
        "     Add .preload(:volumes) to the query that loaded this App::Shelf",
      ]
      boxed.each do |text|
        assert!(human.stdout.includes?(text), "missing #{text.inspect} in:\n#{human.stdout}")
      end
      apply(n_plus_one.stdout)
      patched = File.read(action)
      preload = "App::Shelf.query.preload(:volumes).find!(contract.id)"
      assert!(patched.includes?(preload), patched)
      rechecked = command([@frappe, "check"], chdir: @project, echo: false)
      assert!(rechecked.stdout.starts_with?("OK check "))
      puts "PASS: a planted un-preloaded association yields N_PLUS_ONE " \
           "with a PATCH that makes frappe check pass, " \
           "and --human shows the box, source line, caret and remediation"

      expanded = command([@frappe, "expand", "config/routes.cr:2:3"],
        chdir: @project, echo: false).stdout
      drawn = expanded.includes?("__caramel_router_draw")
      assert!(drawn && expanded.includes?("App::Shelves::Show"), expanded)
      contract = command([@frappe, "expand", "app/actions/shelves/show.cr:3:5"],
        chdir: @project, echo: false).stdout
      location = %(CARAMEL_CONTRACT_LOCATION = ) \
                 %("#{@project}/app/actions/shelves/show.cr:3:5")
      declared = contract.includes?("~> struct Contract < ::Caramel::RequestContract")
      assert!(declared && contract.includes?(location), contract)
      nothing = attempt([@frappe, "expand", "app/actions/shelves/show.cr:6:1"], chdir: @project)
      unexpanded = nothing.stdout.starts_with?("no expansion found")
      assert!(nothing.status.exit_code == 1 && unexpanded, nothing.stdout + nothing.stderr)
      File.delete(model)
      File.delete(action)
      Dir.delete(File.dirname(action))
      File.write(routes, original_routes)
      puts "PASS: frappe expand prints the Crystal that Caramel::Router.draw " \
           "and an action's contract block expand to, " \
           "and exits 1 where no macro is called"

      id = site("bookshelf")["id"].as_s
      created = command([@frappe, "db", "branch", "create", "agent_probe"],
        chdir: @project, echo: false)
      url = created.stdout.chomp
      branch = "@/caramel_branch_#{id}_agent_probe?"
      one_url = created.stdout.lines.size == 1 && url.starts_with?("postgresql://")
      assert!(one_url && url.includes?(branch), created.stdout)
      assert!(sql(url, "SELECT current_database()") == "caramel_branch_#{id}_agent_probe")
      list_branches = [@frappe, "db", "branch", "list"]
      branches = command(list_branches, chdir: @project, echo: false)
      assert!(branches.stdout == "agent_probe\n")
      missing = attempt([@frappe, "dev", "--no-open", "--branch", "absent_probe"],
        chdir: @project, timeout: 60.seconds)
      no_branch = "bookshelf has no database branch absent_probe"
      refused_branch = missing.stderr.includes?(no_branch)
      assert!(missing.status.exit_code == 1 && refused_branch, missing.stderr)
      deleted = command([@frappe, "db", "branch", "delete", "agent_probe"],
        chdir: @project, echo: false)
      assert!(deleted.stdout == "Deleted database branch agent_probe.\n", deleted.stdout)
      listed = command(list_branches, chdir: @project, echo: false)
      none = listed.stderr.includes?("bookshelf has no database branches.")
      assert!(listed.stdout.empty? && none, listed.stdout + listed.stderr)
      puts "PASS: frappe db branch create prints a connectable branch URL; " \
           "list and delete manage it, and frappe dev --branch refuses an absent branch"
    end

    # Applies every `PATCH:` line of MRDP to the file its ERR line names, as a
    # coding agent would.
    def apply(mrdp : String) : Nil
      file = nil
      mrdp.each_line do |line|
        if match = line.match(/\AERR \S+ at ([^:]+):\d+:\d+\z/)
          file = File.join(@project, match[1])
        elsif (match = line.match(/\APATCH: INSERT "(.*)" (AT|AFTER) (\d+):(\d+)\z/)) && file
          lines = File.read_lines(file)
          row, column = match[3].to_i - 1, match[4].to_i
          if match[2] == "AT"
            lines.insert(row, " " * (column - 1) + match[1])
          else
            lines[row] = lines[row].insert(column, match[1])
          end
          File.write(file, lines.join('\n') + "\n")
        end
      end
      assert!(!file.nil?, "no ERR line in #{mrdp}")
    end

    SHELF_ACTION = <<-'CRYSTAL'
      module App::Shelves
        struct Show < App::ApplicationAction
          contract do
          end

          # One shelf's volume titles.
          def handle(contract : Contract)
            page "Shelf", "Shelf #{contract.id}"
          end
        end
      end
      CRYSTAL

    SHELF_MODELS = <<-CRYSTAL
      module App
        struct Shelf < SugarORM::Schema
          schema "shelves" do
            field id : Int64, primary: true
            has_many volumes : Volume
          end
        end

        struct Volume < SugarORM::Schema
          schema "volumes" do
            field id : Int64, primary: true
            field title : String
            belongs_to shelf : Shelf
          end
        end
      end
      CRYSTAL

    # Generated specs and probes run in two Latte test workers: a savepoint
    # hides one example's rows from the next, catalog and leaked DDL reset the
    # worker, a job an action enqueued drains synchronously, and a planted
    # mocking call is refused before anything compiles.
    def corretto(values : Hash(String, String)) : Nil
      mocked = File.join(@project, "spec/requests/mock_probe_spec.cr")
      File.write(mocked, <<-CRYSTAL)
        require "../spec_helper"

        describe "Mocks" do
          it("stubs") { allow(App::Book).to receive(:create) }
        end\n
        CRYSTAL
      refused = attempt([@frappe, "corretto", "--concurrency=2"],
        chdir: @project, timeout: 30.seconds)
      File.delete(mocked)
      mocking = "spec/requests/mock_probe_spec.cr:4: `allow(` is a mocking API"
      located = refused.status.exit_code == 1 && refused.stderr.includes?(mocking)
      counted = refused.stderr.includes?("Specs refused: 1 mocking call")
      assert!(located && counted, refused.stderr)
      assert!(!refused.stdout.includes?("Applied"), refused.stdout)
      puts "PASS: frappe corretto refuses a planted allow( with its file and line " \
           "before migrating or compiling"

      rfc_example

      File.write(File.join(@project, "spec/requests/corretto_probe_spec.cr"), CORRETTO_PROBE)
      File.write(File.join(@project, "app/jobs/probe_job.cr"), PROBE_JOB)
      Dir.mkdir_p(File.join(@project, "app/actions/probe"))
      File.write(File.join(@project, "app/actions/probe/enqueue.cr"), PROBE_ACTION)
      routes = File.join(@project, "config/routes.cr")
      probe_route = %(    post "/probe/jobs", App::Probe::Enqueue\n) \
                    %(    # Frappé resource routes)
      File.write(routes, File.read(routes).sub(RESOURCE_ROUTES, probe_route))
      result = command([@frappe, "corretto", "--concurrency=2"],
        chdir: @project, timeout: 900.seconds)
      output = result.stdout + result.stderr
      spread = result.stdout.includes?("Corretto: 6 spec files across 2 workers")
      passed = result.stdout.includes?("Corretto: 2 of 2 workers passed")
      assert!(spread && passed, output)
      %w[[w1] [w2]].each do |prefix|
        clean = result.stdout.lines.any? do |line|
          line.starts_with?(prefix) && line.includes?(" examples, 0 failures, 0 errors")
        end
        assert!(clean, output)
      end
      assert!(result.stderr.matches?(CATALOG_RESET), output)
      id = site("bookshelf")["id"].as_s
      workers = "SELECT count(*) FROM pg_database " \
                "WHERE starts_with(datname, 'caramel_spec_#{id}_w')"
      assert!(sql(values["SPEC_DATABASE_URL"], workers) == "0")
      puts "PASS: frappe corretto --concurrency=2 runs the generated Corretto specs " \
           "in two Latte test workers with savepoint isolation, catalog resets, " \
           "wire isolation and a synchronously drained Cold Brew job, " \
           "then drops the workers"
    end

    # RFC-0006 §2.1's example spec, copied byte for byte from docs/rfc.md, runs
    # green against the minimal application it describes: top-level User, Team
    # and Notification schemas, a Teams::Create action and a Cold Brew job.
    def rfc_example : Nil
      rfc = File.read_lines(File.join(@repo, "docs/rfc.md"), chomp: false)
      heading = "# spec/actions/teams/create_spec.cr\n"
      start = rfc.index(heading) || raise "docs/rfc.md lacks the RFC-0006 example spec"
      assert!(rfc[start - 1] == "```crystal\n",
        "the RFC-0006 example must start a crystal code block")
      closing = (start...rfc.size).find { |index| rfc[index].starts_with?("```") }
      finish = closing || raise "the RFC-0006 example code block is not closed"
      example = rfc[start...finish].join
      described = example.includes?("describe Teams::Create do")
      notified = "Notification::Query.where(user_id: user.id).count(db).should eq(1)"
      assert!(described && example.includes?(notified), example)
      spec = File.join(@project, "spec/actions/teams/create_spec.cr")
      Dir.mkdir_p(File.dirname(spec))
      File.write(spec, example)
      RFC_APP.each do |relative, source|
        Dir.mkdir_p(File.join(@project, File.dirname(relative)))
        File.write(File.join(@project, relative), source)
      end
      routes = File.join(@project, "config/routes.cr")
      teams_route = %(    post "/teams", Teams::Create\n    # Frappé resource routes)
      File.write(routes, File.read(routes).sub(RESOURCE_ROUTES, teams_route))

      before = Dir.glob(File.join(@project, "db/migrations/*.cr"))
      command([@frappe, "db", "diff", "--name", "create_teams"],
        chdir: @project, timeout: 300.seconds)
      derived = Dir.glob(File.join(@project, "db/migrations/*.cr")) - before
      assert!(!derived.empty? && derived.all?(&.includes?("_create_teams")), derived.inspect)
      migrated = command([@frappe, "migrate"], chdir: @project, timeout: 300.seconds)
      assert!(migrated.stdout.includes?(MATCHED), migrated.stdout)

      result = command([@frappe, "corretto", "spec/actions/teams/create_spec.cr"],
        chdir: @project, timeout: 600.seconds)
      assert!(File.read(spec) == example, "the RFC-0006 example spec changed on disk")
      ran = result.stdout.includes?("[w1] 1 examples, 0 failures, 0 errors, 0 pending")
      passed = result.stdout.includes?("Corretto: 1 of 1 workers passed")
      assert!(ran && passed, result.stdout + result.stderr)
      puts "PASS: RFC-0006 §2.1's example spec, verbatim from docs/rfc.md, " \
           "passes under frappe corretto with a derived create_teams migration " \
           "and a drained Cold Brew notification job"
    end

    # The list item the RFC's Teams::Create action renders. It is a raw
    # literal, so its interpolations reach the generated source as written.
    TEAM_ITEM = %q(<li>#{Caramel::HTML.escape(created.name)} · #{created.seats} seats</li>)

    RFC_APP = {
      "app/models/user.cr" => <<-CRYSTAL,
        struct User < SugarORM::Schema
          schema "users" do
            field id : Int64, primary: true
            field email : String
          end
        end
        CRYSTAL
      "app/models/team.cr" => <<-CRYSTAL,
        struct Team < SugarORM::Schema
          schema "teams" do
            field id : Int64, primary: true
            field name : String
            field seats : Int32
            belongs_to owner : User
          end
        end
        CRYSTAL
      "app/models/notification.cr" => <<-CRYSTAL,
        struct Notification < SugarORM::Schema
          schema "notifications" do
            field id : Int64, primary: true
            belongs_to user : User
          end
        end
        CRYSTAL
      "app/jobs/notify_team_owner.cr" => <<-CRYSTAL,
        # Tells a team's owner that the team exists.
        struct NotifyTeamOwner < Caramel::ColdBrew::Job
          param user_id : Int64

          def perform
            Notification.create!(user_id: user_id)
          end
        end
        CRYSTAL
      "app/actions/teams/create.cr" => <<-CRYSTAL,
        module Teams
          struct Create < App::ApplicationAction
            contract do
              field name : String
              field seats : Int32, min: 1
            end

            # The signed-in user owns the new team; the owner's notification is
            # enqueued in the same transaction, so it exists only if the team does.
            def handle(contract : Contract)
              owner_id = session["user_id"]?.try(&.to_i64?)
              return Caramel::Response.new(403, "Sign in to create a team") unless owner_id
              team = nil.as(Team?)
              SugarORM::Repo.transaction do
                team = Team.create!(name: contract.name, seats: contract.seats, owner_id: owner_id)
                NotifyTeamOwner.enqueue(user_id: owner_id)
              end
              created = team.not_nil!
              partials [Caramel::Partial.new("#team-list", "#{TEAM_ITEM}", "innerMorph")]
            end
          end
        end
        CRYSTAL
    }

    CORRETTO_PROBE = <<-CRYSTAL
      require "../spec_helper"

      describe "Corretto isolation probe" do
        it "creates a book inside the example's savepoint" do
          Corretto.session do |client, db|
            App::Book.create!(db, title: "Savepoint probe", author: "Corretto")
            db.should have_row(App::Book, title: "Savepoint probe")
          end
        end

        it "no longer sees the previous example's book" do
          Corretto.session do |client, db|
            db.should_not have_row(App::Book, title: "Savepoint probe")
            App::Book.query.count(db).should eq(0)
          end
        end

        it "runs DDL unwrapped as a catalog example", tags: "catalog" do
          Corretto.session do |client, db|
            db.exec("CREATE INDEX CONCURRENTLY catalog_probe ON books (title)")
            db.exec("CREATE TABLE catalog_probe_table (id integer)")
          end
        end

        it "leaks DDL through a second connection" do
          leak = Caramel::Database.open(Caramel::Database.url(migration: true), 1)
          leak.exec("CREATE TABLE leaked_probe (id integer)")
          leak.close
        end

        it "starts from the migrated template after each reset \
          and answers outbound HTTP only from stubs" do
          Corretto.session do |client, db|
            %w(catalog_probe catalog_probe_table leaked_probe).each do |relation|
              db.query_one("SELECT to_regclass($1)::text", relation, as: String?).should be_nil
            end
            client.get("/books").should render_page("Books")
            Caramel::Outbound.get("https://api.stripe.com/v1/customers").status_code.should eq(502)
            Corretto.stub_wire("https://api.stripe.com/v1/customers", \
              method: "GET").to_return(status: 200, body: %({"data":[]}), \
              headers: {"Content-Type" => "application/json"})
            Caramel::Outbound.get("https://api.stripe.com/v1/customers").body.should \
              eq(%({"data":[]}))
            Corretto.wire_requests.size.should eq(2)
          end
        end

        it "starts each example with no wire stubs" do
          Corretto.wire_requests.should be_empty
          Caramel::Outbound.get("https://api.stripe.com/v1/customers").status_code.should eq(502)
        end

        it "drains the job an action enqueued, \
          synchronously and inside the example's transaction" do
          Corretto.session do |client, db|
            client.post("/probe/jobs", headers: {"HX-Request" => "true"}, \
              params: {"title" => "Drained probe"}).should render_partial("#jobs")
            db.should_not have_row(App::Book, title: "Drained probe")
            Caramel::ColdBrew.drain_queue!(db, "default").should eq(1)
            db.should have_row(App::Book, title: "Drained probe", author: "Cold Brew")
            Caramel::ColdBrew.drain_queue!(db, "default").should eq(0)
          end
        end

        it "rolled back the drained job's writes" do
          Corretto.session do |client, db|
            db.should_not have_row(App::Book, title: "Drained probe")
          end
        end
      end
      CRYSTAL

    # A Cold Brew job, and the action that enqueues it, which the probe spec drains.
    PROBE_JOB = <<-CRYSTAL
      module App
        struct ProbeJob < Caramel::ColdBrew::Job
          param title : String

          def perform
            App::Book.create!(title: title, author: "Cold Brew")
          end
        end
      end
      CRYSTAL

    PROBE_ACTION = <<-'CRYSTAL'
      module App::Probe
        struct Enqueue < App::ApplicationAction
          contract do
            field title : String
          end

          def handle(contract : Contract)
            App::ProbeJob.enqueue(title: contract.title)
            morph("#jobs", "Queued #{Caramel::HTML.escape(contract.title)}")
          end
        end
      end
      CRYSTAL
  end
end

require "./frappe_project/dev"
require "./frappe_project/benchmark"

begin
  Caramel::Checks::FrappeProject.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
