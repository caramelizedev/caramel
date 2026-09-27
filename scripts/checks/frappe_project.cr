require "./support/latte_fixture"
require "uri"
require "http/params"

module Caramel::Checks
  class FrappeProject < LatteFixture
    getter project : String

    def initialize
      toolchain = Checks.toolchain_root("Set CARAMEL_TOOLCHAIN_ROOT to the managed toolchain")
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
      failed = true
      begin
        start
        command([@frappe, "new", "bookshelf"], chdir: @projects)
        values = local_values(@project)
        assert!(File.info(File.join(@project, ".env")).permissions.value == 0o600)
        urls = %w(DATABASE_URL MIGRATION_DATABASE_URL SPEC_DATABASE_URL SPEC_MIGRATION_DATABASE_URL).map { |key| values[key] }
        assert!(urls.uniq.size == 4)
        command([@frappe, "make", "resource", "Book", "title:string", "author:string"], chdir: @project)
        command([@frappe, "make", "resource", "Person", "name:string", "age:int32", "total:int64", "active:bool", "rating:float64?", "joined_at:time?", "--plural=people"], chdir: @project)
        routes = command([@frappe, "routes"], chdir: @project, echo: false).stdout
        print routes
        assert!(routes.lines.any? { |line| line.split == %w(GET /books/:id App::Books::Show id:Int64(min=1)) }, routes)
        assert!(routes.lines.any? { |line| line.split == %w(PATCH /people/:id App::People::Update id:Int64(min=1) name:String age:Int32 total:Int64 active:Bool rating:Float64? joined_at:Time?) }, routes)
        migrated = command([@frappe, "migrate"], chdir: @project)
        assert!(migrated.stdout.includes?("The database matches the declared schema."), migrated.stdout)
        # The generated create_* migrations must be exactly what the differ
        # derives, so diffing the migrated database finds nothing to write.
        probe = command([@frappe, "db", "diff", "--name", "drift_probe"], chdir: @project, timeout: 300.seconds)
        assert!(probe.stdout.includes?("already matches the declared schema; no migration was written"), probe.stdout)
        assert!(Dir.glob(File.join(@project, "db/migrations/*drift_probe*")).empty?)
        puts "PASS: generated SugarORM resources migrate without drift, and frappe db diff --name drift_probe derives nothing"
        sql(values["MIGRATION_DATABASE_URL"], "CREATE TABLE dev_sentinel (value text NOT NULL); INSERT INTO dev_sentinel VALUES ('keep');")
        command([@frappe, "test"], chdir: @project)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")
        env_path = File.join(@project, ".env")
        original_env = File.read(env_path)
        changed = original_env.sub("SPEC_DATABASE_URL=#{values["SPEC_DATABASE_URL"].to_json}", "SPEC_DATABASE_URL=#{values["DATABASE_URL"].to_json}")
        assert!(changed != original_env)
        File.write(env_path, changed)
        refused = attempt([@frappe, "test"], chdir: @project, timeout: 30.seconds)
        assert!(!refused.success? && refused.stderr.includes?("test refused"), refused.stderr)
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
          next if %w(lib .caramel .env).includes?(entry)
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
        command([@frappe, "test"], chdir: clone)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")

        injected = File.join(@root, "package-with-failed-installer")
        Dir.mkdir(injected)
        %w(src templates vendor).each { |folder| command(["/bin/cp", "-R", File.join(@repo, folder), File.join(injected, folder)], echo: false) }
        %w(shard.yml shard.lock LICENSE THIRD_PARTY_NOTICES.md).each { |name| File.copy(File.join(@repo, name), File.join(injected, name)) }
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

        Dev.new(self, clone).check if args.includes?("--dev")
        Benchmark.new(self, edit_only: args.includes?("--edit-benchmark")).check if args.includes?("--benchmark") || args.includes?("--edit-benchmark")

        serve(@project, "bookshelf", values)
        page = command(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*", "--cacert", certificate, "--resolve", "bookshelf.caramel:#{@ports[2]}:127.0.0.1", "-H", "Host: bookshelf.caramel", "https://bookshelf.caramel:#{@ports[2]}/"], echo: false)
        assert!(page.stdout.includes?("A little less setup.") && page.stdout.includes?("/assets/htmx-4.0.0.min.js"))
        puts "PASS: real frappe new/setup/migrate/routes/test, clone secrets, failed-dependency recovery, source preservation, test refusal for development URL, retained development data, and generated native app over CA-verified named HTTPS"
        failed = false
      ensure
        finish(failed)
      end
    end
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
