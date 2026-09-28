require "./support/latte_fixture"
require "../../src/frappe/commands"
require "uri"
require "http/params"

module Caramel::Checks
  class FrappeProject < LatteFixture
    getter project : String

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
      command([@psql, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", query["host"], "-p", query["port"]? || "5432", "-U", URI.decode(uri.user.not_nil!), "-d", uri.path.lchop('/')], environment: pg_env, input: statement, echo: false, timeout: 15.seconds).stdout.strip
    end

    def execute(args : Array(String)) : Nil
      puts "Frappé fixture: #{@root}"
      # ameba:disable Lint/UselessAssign
      failed = true
      begin
        start
        command([@frappe, "new", "bookshelf"], chdir: @projects)
        values = local_values(@project)
        assert!(File.info(File.join(@project, ".env")).permissions.value == 0o600)
        urls = %w[DATABASE_URL MIGRATION_DATABASE_URL SPEC_DATABASE_URL SPEC_MIGRATION_DATABASE_URL].map { |key| values[key] }
        assert!(urls.uniq.size == 4)
        command([@frappe, "make", "resource", "Book", "title:string", "author:string"], chdir: @project)
        command([@frappe, "make", "resource", "Person", "name:string", "age:int32", "total:int64", "active:bool", "rating:float64?", "joined_at:time?", "--plural=people"], chdir: @project)
        routes = command([@frappe, "routes"], chdir: @project, echo: false).stdout
        print routes
        assert!(routes.lines.any? { |line| line.split == %w[GET /books/:id App::Books::Show id:Int64(min=1)] }, routes)
        assert!(routes.lines.any? { |line| line.split == %w[PATCH /people/:id App::People::Update id:Int64(min=1) name:String age:Int32 total:Int64 active:Bool rating:Float64? joined_at:Time?] }, routes)
        agent_tooling
        migrated = command([@frappe, "migrate"], chdir: @project)
        assert!(migrated.stdout.includes?("The database matches the declared schema."), migrated.stdout)
        # The generated create_* migrations must be exactly what the differ
        # derives, so diffing the migrated database finds nothing to write.
        probe = command([@frappe, "db", "diff", "--name", "drift_probe"], chdir: @project, timeout: 300.seconds)
        assert!(probe.stdout.includes?("already matches the declared schema; no migration was written"), probe.stdout)
        assert!(Dir.glob(File.join(@project, "db/migrations/*drift_probe*")).empty?)
        puts "PASS: generated SugarORM resources migrate without drift, and frappe db diff --name drift_probe derives nothing"
        sql(values["MIGRATION_DATABASE_URL"], "CREATE TABLE dev_sentinel (value text NOT NULL); INSERT INTO dev_sentinel VALUES ('keep');")
        corretto(values)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")
        env_path = File.join(@project, ".env")
        original_env = File.read(env_path)
        changed = original_env.sub("SPEC_DATABASE_URL=#{values["SPEC_DATABASE_URL"].to_json}", "SPEC_DATABASE_URL=#{values["DATABASE_URL"].to_json}")
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
          command(["/bin/cp", "-R", File.join(@project, entry), File.join(clone, entry)], echo: false)
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
        %w[src templates vendor].each { |folder| command(["/bin/cp", "-R", File.join(@repo, folder), File.join(injected, folder)], echo: false) }
        %w[shard.yml shard.lock LICENSE THIRD_PARTY_NOTICES.md].each { |name| File.copy(File.join(@repo, name), File.join(injected, name)) }
        Dir.mkdir(File.join(injected, "scripts"))
        failed_shards = File.join(injected, "scripts/shards")
        File.write(failed_shards, "#!/bin/sh\nexit 67\n")
        File.chmod(failed_shards, 0o700)
        interrupted = attempt([@frappe, "new", "resumed"], chdir: @projects, timeout: 40.seconds, environment: environment({"CARAMEL_FRAMEWORK_ROOT" => injected}))
        assert!(!interrupted.success? && interrupted.stderr.includes?("frappe setup to resume"), interrupted.stderr)
        resumed = File.join(@projects, "resumed")
        resume_readme = File.join(resumed, "README.md")
        File.write(resume_readme, File.read(resume_readme) + "\nPreserve this edit during setup.\n")
        command([@frappe, "setup"], chdir: resumed)
        assert!(File.read(resume_readme).ends_with?("Preserve this edit during setup.\n"))
        dump = command([@frappe, "db", "dump"], chdir: @project, echo: false)
        backup = dump.stdout.lines.last.strip.split(": ", 2).last
        assert!(backup.starts_with?(File.join(@state, "backups") + "/") && File.info(backup).permissions.value == 0o600, dump.stdout)
        sql(values["MIGRATION_DATABASE_URL"], "DELETE FROM dev_sentinel")
        restored = command([@frappe, "db", "restore", backup], chdir: @project, echo: false)
        assert!(restored.stdout.includes?("Saved the current development database to"), restored.stdout)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")
        missing_log = attempt([@frappe, "logs"], chdir: @project)
        assert!(missing_log.status.exit_code == 1 && missing_log.stderr.includes?("No app log for bookshelf yet"), missing_log.stderr)

        resumed_id = site("resumed")["id"].as_s
        resumed_url = local_values(resumed)["DATABASE_URL"]
        removed = command([@frappe, "sites", "remove", "resumed"], echo: false)
        assert!(removed.stdout.includes?("Removed resumed"), removed.stdout)
        assert!(rpc("GET", "/v1/sites")["sites"].as_a.none? { |entry| entry["name"].as_s == "resumed" })
        assert!(File.exists?(File.join(@state, "secrets", "site-#{resumed_id}.json")))
        command([@frappe, "setup"], chdir: resumed, echo: false)
        assert!(site("resumed")["id"].as_s == resumed_id && local_values(resumed)["DATABASE_URL"] == resumed_url)
        puts "PASS: frappe db dump/restore with safety dump, missing-log guidance, and site removal with retained data and re-registration"
        git_source

        Dev.new(self, clone).check if args.includes?("--dev")
        Benchmark.new(self, edit_only: args.includes?("--edit-benchmark")).check if args.includes?("--benchmark") || args.includes?("--edit-benchmark")

        serve(@project, "bookshelf", values)
        page = command(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*", "--cacert", certificate, "--resolve", "bookshelf.caramel:#{@ports[2]}:127.0.0.1", "-H", "Host: bookshelf.caramel", "https://bookshelf.caramel:#{@ports[2]}/"], echo: false)
        assert!(page.stdout.includes?("A little less setup.") && page.stdout.includes?("/assets/htmx-4.0.0.min.js"))
        puts "PASS: real frappe new/setup/migrate/routes/corretto, clone secrets, failed-dependency recovery, source preservation, spec refusal for development URL, retained development data, and generated native app over CA-verified named HTTPS"
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
      command([@frappe, "new", "tagged"], chdir: @projects, environment: environment({"CARAMEL_REPOSITORY" => url}))
      tagged = File.join(@projects, "tagged")
      assert!(File.read(File.join(tagged, "shard.yml")).ends_with?(%(  caramel:\n    git: #{url.to_json}\n    version: "~> #{Caramel::VERSION}"\n)))
      assert!(File.read(File.join(tagged, "shard.lock")).includes?(%(  caramel:\n    git: #{url.to_json}\n    version: #{Caramel::VERSION}\n)))
      library = File.join(tagged, "lib/caramel")
      assert!(File.info(library, follow_symlinks: false).directory? && File.file?(File.join(library, "src/caramel/command_line.cr")), "lib/caramel is not the tagged release")
      checked = command([@frappe, "check"], chdir: tagged, echo: false)
      assert!(checked.stdout.starts_with?("OK check "), checked.stdout)
      puts "PASS: frappe new against a repository tagged v#{Caramel::VERSION} resolves the framework by git, migrates and type-checks"
    end

    # RFC-0005 agent tooling on the generated project: the stateless manifest,
    # strict usage errors, the routes filter, Tier-1 `frappe check` with MRDP
    # whose PATCH lines are applied mechanically until the check passes, the
    # human typography, `frappe expand` and database branches.
    def agent_tooling : Nil
      absent = environment({"CARAMEL_HOME" => File.join(@root, "absent-latte")})
      manifest = command([@frappe, "agent-manifest"], chdir: "/", environment: absent, echo: false).stdout.lines
      assert!(manifest.first? == "CARAMEL CLI INTERFACE (STRICT TOKENS)", manifest.first?.to_s)
      assert!(manifest[1]? == "VERSION: #{Caramel::VERSION}", manifest[1]?.to_s)
      Caramel::Frappe::Commands::TABLE.each do |entry|
        assert!(manifest.includes?("frappe #{entry.syntax}  # #{entry.summary}"), "manifest lacks frappe #{entry.syntax}")
      end
      ["check [--agent|--human]", "lint [--agent|--human]", "format", "routes [FILTER]", "db branch create NAME", "db diff --name NAME", "corretto [SPEC_PATHS...]", "expand FILE:LINE:COL"].each do |syntax|
        assert!(manifest.any?(&.starts_with?("frappe #{syntax}")), "manifest lacks frappe #{syntax}")
      end
      assert!(manifest.any?(&.starts_with?(%(PATCH: INSERT "<text>" AT <line>:<col>))), manifest.join("\n"))
      unknown = attempt([@frappe, "routes", "--verbose"], chdir: @project)
      assert!(unknown.status.exit_code == 1 && unknown.stderr == "ERR USAGE at frappe routes\nMSG: unknown option --verbose\nSYNTAX: frappe routes [FILTER]\n", unknown.stderr)
      typo = attempt([@frappe, "chek", "--human"], chdir: @project)
      assert!(typo.status.exit_code == 1 && typo.stderr.includes?("Usage: frappe check [--agent|--human]\nDid you mean check?"), typo.stderr)
      puts "PASS: frappe agent-manifest lists every command without Latte, and unknown input exits 1 with the exact syntax and a suggestion"

      people = command([@frappe, "routes", "people"], chdir: @project, echo: false).stdout.lines
      assert!(people.size == 7 && people.all? { |line| line.split[1].starts_with?("/people") && line.split[2].starts_with?("App::People::") }, people.join("\n"))
      patches = command([@frappe, "routes", "patch"], chdir: @project, echo: false).stdout.lines
      assert!(patches.map { |line| line.split[0, 2] } == [%w[PATCH /books/:id], %w[PATCH /people/:id]], patches.join("\n"))
      assert!(command([@frappe, "routes", "no-such-route"], chdir: @project, echo: false).stdout.empty?)
      puts "PASS: frappe routes FILTER keeps routes whose method, path or action contains it, ignoring case"

      assert!(File.file?(File.join(@project, ".ameba.yml")), "the generated application lacks its rule set, .ameba.yml")
      linted = command([@frappe, "lint"], chdir: @project, echo: false)
      assert!(linted.stdout.matches?(/\AOK lint \d+ files\n\z/), linted.stdout)
      noun = File.join(@project, "app/models/invitation_service.cr")
      File.write(noun, "module App\n  class  InvitationService\n  end\nend\n")
      flagged = attempt([@frappe, "lint", "--agent"], chdir: @project)
      assert!(flagged.status.exit_code == 1 && flagged.stdout.starts_with?(<<-MRDP), flagged.stdout + flagged.stderr)
        ERR LINT_LINT_FORMATTING at app/models/invitation_service.cr:1:1
        MSG: Use built-in formatter to format this source (Lint/Formatting)
        FIX: frappe format
        ERR LINT_CARAMEL_SERVICE_NOUN at app/models/invitation_service.cr:2:10\n
        MRDP
      command([@frappe, "format"], chdir: @project, echo: false)
      assert!(File.read(noun) == "module App\n  class InvitationService\n  end\nend\n", File.read(noun))
      File.delete(noun)
      assert!(command([@frappe, "lint"], chdir: @project, echo: false).stdout.starts_with?("OK lint "))
      puts "PASS: the generated application and its resources pass frappe lint; a planted service noun yields ERR LINT_CARAMEL_SERVICE_NOUN, and frappe format fixes its layout"

      clean = command([@frappe, "check"], chdir: @project, echo: false)
      assert!(clean.stdout.matches?(/\AOK check \d+ files\n\z/), clean.stdout)
      assert!(command([@frappe, "check", "--human"], chdir: @project, echo: false).stdout == "✓ Type check passed\n")

      action = File.join(@project, "app/actions/shelves/show.cr")
      Dir.mkdir_p(File.dirname(action))
      File.write(action, SHELF_ACTION)
      routes = File.join(@project, "config/routes.cr")
      original_routes = File.read(routes)
      File.write(routes, original_routes.sub("    # Frappé resource routes", %(    get "/shelves/:id", App::Shelves::Show\n    # Frappé resource routes)))
      mismatch = attempt([@frappe, "check"], chdir: @project)
      assert!(mismatch.status.exit_code == 1 && mismatch.stdout == <<-MRDP, mismatch.stdout + mismatch.stderr)
        ERR CONTRACT_MISMATCH:422 at app/actions/shelves/show.cr:3:5
        NODE: RequestContract
        MISSING: id:Int64
        PATCH: INSERT "field id : Int64" AT 4:7\n
        MRDP
      apply(mismatch.stdout)
      repaired = command([@frappe, "check"], chdir: @project, echo: false)
      assert!(repaired.stdout.starts_with?("OK check "), repaired.stdout)
      puts "PASS: a planted route-contract mismatch yields MRDP with a PATCH, and applying the PATCH line mechanically makes frappe check pass"

      model = File.join(@project, "app/models/shelf.cr")
      File.write(model, SHELF_MODELS)
      File.write(action, File.read(action).sub(%(page "Shelf", "Shelf \#{contract.id}"), %(titles = App::Shelf.query.find!(contract.id).volumes.map(&.title)\n      page "Shelf", titles.join(", "))))
      n_plus_one = attempt([@frappe, "check", "--agent"], chdir: @project)
      assert!(n_plus_one.status.exit_code == 1 && n_plus_one.stdout == <<-MRDP, n_plus_one.stdout + n_plus_one.stderr)
        ERR N_PLUS_ONE at app/actions/shelves/show.cr:9:52
        MSG: Association 'volumes' of App::Shelf was not preloaded.
        PATCH: INSERT ".preload(:volumes)" AFTER 9:31\n
        MRDP
      human = attempt([@frappe, "check", "--human"], chdir: @project)
      assert!(human.status.exit_code == 1 && !human.stdout.includes?("\e["), human.stdout)
      ["  ╭─[ app/actions/shelves/show.cr:9 ]\n", "  │  9 │       titles = App::Shelf.query.find!(contract.id).volumes.map(&.title)\n",
       "  │    │ #{" " * 51}^^^^^^^ Association 'volumes' of App::Shelf was not preloaded.\n",
       "  ╰─ Accessing un-preloaded relationships triggers runtime N+1 queries.\n",
       "     Remediation:\n     Add .preload(:volumes) to the query that loaded this App::Shelf",
      ].each { |text| assert!(human.stdout.includes?(text), "missing #{text.inspect} in:\n#{human.stdout}") }
      apply(n_plus_one.stdout)
      assert!(File.read(action).includes?("App::Shelf.query.preload(:volumes).find!(contract.id)"), File.read(action))
      assert!(command([@frappe, "check"], chdir: @project, echo: false).stdout.starts_with?("OK check "))
      puts "PASS: a planted un-preloaded association yields N_PLUS_ONE with a PATCH that makes frappe check pass, and --human shows the box, source line, caret and remediation"

      expanded = command([@frappe, "expand", "config/routes.cr:2:3"], chdir: @project, echo: false).stdout
      assert!(expanded.includes?("__caramel_router_draw") && expanded.includes?("App::Shelves::Show"), expanded)
      contract = command([@frappe, "expand", "app/actions/shelves/show.cr:3:5"], chdir: @project, echo: false).stdout
      assert!(contract.includes?("~> struct Contract < ::Caramel::RequestContract") && contract.includes?(%(CARAMEL_CONTRACT_LOCATION = "#{@project}/app/actions/shelves/show.cr:3:5")), contract)
      nothing = attempt([@frappe, "expand", "app/actions/shelves/show.cr:6:1"], chdir: @project)
      assert!(nothing.status.exit_code == 1 && nothing.stdout.starts_with?("no expansion found"), nothing.stdout + nothing.stderr)
      File.delete(model)
      File.delete(action)
      Dir.delete(File.dirname(action))
      File.write(routes, original_routes)
      puts "PASS: frappe expand prints the Crystal that Caramel::Router.draw and an action's contract block expand to, and exits 1 where no macro is called"

      id = site("bookshelf")["id"].as_s
      created = command([@frappe, "db", "branch", "create", "agent_probe"], chdir: @project, echo: false)
      url = created.stdout.chomp
      assert!(created.stdout.lines.size == 1 && url.starts_with?("postgresql://") && url.includes?("@/caramel_branch_#{id}_agent_probe?"), created.stdout)
      assert!(sql(url, "SELECT current_database()") == "caramel_branch_#{id}_agent_probe")
      assert!(command([@frappe, "db", "branch", "list"], chdir: @project, echo: false).stdout == "agent_probe\n")
      missing = attempt([@frappe, "dev", "--no-open", "--branch", "absent_probe"], chdir: @project, timeout: 60.seconds)
      assert!(missing.status.exit_code == 1 && missing.stderr.includes?("bookshelf has no database branch absent_probe"), missing.stderr)
      deleted = command([@frappe, "db", "branch", "delete", "agent_probe"], chdir: @project, echo: false)
      assert!(deleted.stdout == "Deleted database branch agent_probe.\n", deleted.stdout)
      listed = command([@frappe, "db", "branch", "list"], chdir: @project, echo: false)
      assert!(listed.stdout.empty? && listed.stderr.includes?("bookshelf has no database branches."), listed.stdout + listed.stderr)
      puts "PASS: frappe db branch create prints a connectable branch URL; list and delete manage it, and frappe dev --branch refuses an absent branch"
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
      File.write(mocked, %(require "../spec_helper"\n\ndescribe "Mocks" do\n  it("stubs") { allow(App::Book).to receive(:create) }\nend\n))
      refused = attempt([@frappe, "corretto", "--concurrency=2"], chdir: @project, timeout: 30.seconds)
      File.delete(mocked)
      assert!(refused.status.exit_code == 1 && refused.stderr.includes?("spec/requests/mock_probe_spec.cr:4: `allow(` is a mocking API") && refused.stderr.includes?("Specs refused: 1 mocking call"), refused.stderr)
      assert!(!refused.stdout.includes?("Applied"), refused.stdout)
      puts "PASS: frappe corretto refuses a planted allow( with its file and line before migrating or compiling"

      rfc_example

      File.write(File.join(@project, "spec/requests/corretto_probe_spec.cr"), CORRETTO_PROBE)
      File.write(File.join(@project, "app/jobs/probe_job.cr"), PROBE_JOB)
      Dir.mkdir_p(File.join(@project, "app/actions/probe"))
      File.write(File.join(@project, "app/actions/probe/enqueue.cr"), PROBE_ACTION)
      routes = File.join(@project, "config/routes.cr")
      File.write(routes, File.read(routes).sub("    # Frappé resource routes", %(    post "/probe/jobs", App::Probe::Enqueue\n    # Frappé resource routes)))
      result = command([@frappe, "corretto", "--concurrency=2"], chdir: @project, timeout: 900.seconds)
      output = result.stdout + result.stderr
      assert!(result.stdout.includes?("Corretto: 5 spec files across 2 workers") && result.stdout.includes?("Corretto: 2 of 2 workers passed"), output)
      %w[[w1] [w2]].each do |prefix|
        assert!(result.stdout.lines.any? { |line| line.starts_with?(prefix) && line.includes?(" examples, 0 failures, 0 errors") }, output)
      end
      assert!(result.stderr.matches?(/corretto_probe_spec\.cr:25 changed the database catalog outside its transaction; worker [12] was reset/), output)
      id = site("bookshelf")["id"].as_s
      assert!(sql(values["SPEC_DATABASE_URL"], "SELECT count(*) FROM pg_database WHERE starts_with(datname, 'caramel_spec_#{id}_w')") == "0")
      puts "PASS: frappe corretto --concurrency=2 runs the generated Corretto specs in two Latte test workers with savepoint isolation, catalog resets, wire isolation and a synchronously drained Cold Brew job, then drops the workers"
    end

    # RFC-0006 §2.1's example spec, copied byte for byte from docs/rfc.md, runs
    # green against the minimal application it describes: top-level User, Team
    # and Notification schemas, a Teams::Create action and a Cold Brew job.
    def rfc_example : Nil
      rfc = File.read_lines(File.join(@repo, "docs/rfc.md"), chomp: false)
      start = rfc.index { |line| line == "# spec/actions/teams/create_spec.cr\n" } || raise "docs/rfc.md lacks the RFC-0006 example spec"
      assert!(rfc[start - 1] == "```crystal\n", "the RFC-0006 example must start a crystal code block")
      finish = (start...rfc.size).find { |index| rfc[index].starts_with?("```") } || raise "the RFC-0006 example code block is not closed"
      example = rfc[start...finish].join
      assert!(example.includes?("describe Teams::Create do") && example.includes?("Notification::Query.where(user_id: user.id).count(db).should eq(1)"), example)
      spec = File.join(@project, "spec/actions/teams/create_spec.cr")
      Dir.mkdir_p(File.dirname(spec))
      File.write(spec, example)
      RFC_APP.each do |relative, source|
        Dir.mkdir_p(File.join(@project, File.dirname(relative)))
        File.write(File.join(@project, relative), source)
      end
      routes = File.join(@project, "config/routes.cr")
      File.write(routes, File.read(routes).sub("    # Frappé resource routes", %(    post "/teams", Teams::Create\n    # Frappé resource routes)))

      before = Dir.glob(File.join(@project, "db/migrations/*.cr"))
      command([@frappe, "db", "diff", "--name", "create_teams"], chdir: @project, timeout: 300.seconds)
      derived = Dir.glob(File.join(@project, "db/migrations/*.cr")) - before
      assert!(!derived.empty? && derived.all?(&.includes?("_create_teams")), derived.inspect)
      migrated = command([@frappe, "migrate"], chdir: @project, timeout: 300.seconds)
      assert!(migrated.stdout.includes?("The database matches the declared schema."), migrated.stdout)

      result = command([@frappe, "corretto", "spec/actions/teams/create_spec.cr"], chdir: @project, timeout: 600.seconds)
      assert!(File.read(spec) == example, "the RFC-0006 example spec changed on disk")
      assert!(result.stdout.includes?("[w1] 1 examples, 0 failures, 0 errors, 0 pending") && result.stdout.includes?("Corretto: 1 of 1 workers passed"), result.stdout + result.stderr)
      puts "PASS: RFC-0006 §2.1's example spec, verbatim from docs/rfc.md, passes under frappe corretto with a derived create_teams migration and a drained Cold Brew notification job"
    end

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
      "app/actions/teams/create.cr" => <<-'CRYSTAL',
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
              partials [Caramel::Partial.new("#team-list", "<li>#{Caramel::HTML.escape(created.name)} · #{created.seats} seats</li>", "innerMorph")]
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

        it "starts from the migrated template after each reset and answers outbound HTTP only from stubs" do
          Corretto.session do |client, db|
            %w(catalog_probe catalog_probe_table leaked_probe).each do |relation|
              db.query_one("SELECT to_regclass($1)::text", relation, as: String?).should be_nil
            end
            client.get("/books").should render_page("Books")
            Caramel::Outbound.get("https://api.stripe.com/v1/customers").status_code.should eq(502)
            Corretto.stub_wire("https://api.stripe.com/v1/customers", method: "GET").to_return(status: 200, body: %({"data":[]}), headers: {"Content-Type" => "application/json"})
            Caramel::Outbound.get("https://api.stripe.com/v1/customers").body.should eq(%({"data":[]}))
            Corretto.wire_requests.size.should eq(2)
          end
        end

        it "starts each example with no wire stubs" do
          Corretto.wire_requests.should be_empty
          Caramel::Outbound.get("https://api.stripe.com/v1/customers").status_code.should eq(502)
        end

        it "drains the job an action enqueued, synchronously and inside the example's transaction" do
          Corretto.session do |client, db|
            client.post("/probe/jobs", headers: {"HX-Request" => "true"}, params: {"title" => "Drained probe"}).should render_partial("#jobs")
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
