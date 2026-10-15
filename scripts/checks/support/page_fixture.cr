require "./latte_fixture"
require "../../../src/frappe/commands"
require "../../../src/caramel"
require "../../../src/caramel/corretto/matchers"

module Caramel::Checks
  # A check that follows one website page step by step: it creates the
  # application the page creates, copies each file at the step where the page
  # shows it, and runs each command where the page runs it. The page's files
  # live in spec/fixtures/pages/<page key>/ with the paths they have in the
  # application, and website/check.mjs holds the page's snippets to them.
  abstract class PageFixture < LatteFixture
    include Corretto::Matchers
    getter project : String
    getter fixture : String

    MATCHED         = "The database matches the declared schema."
    RESOURCE_ROUTES = "    # Frappé resource routes"

    # *page* is the page's key in site.html; *name* the application's name.
    def initialize(page : String, name : String)
      super("caramel-page-#{page}-")
      @name = name
      @fixture = File.join(Checks::REPO, "spec/fixtures/pages", page)
      @project = File.join(@projects, name)
    end

    # What the page does, in its order. Raises on the first step that fails.
    abstract def follow : Nil

    # What a passing run prints after PASS.
    abstract def proves : String

    def execute(args : Array(String)) : Nil
      puts "Page fixture: #{@root}"
      # ameba:disable Lint/UselessAssign -- read by the ensure below
      failed = true
      begin
        start
        follow
        puts "PASS: #{proves}"
        failed = false
      ensure
        finish(failed)
      end
    end

    # `frappe new`, asserting the two lines the Learn page expects.
    def create : Nil
      made = command([@frappe, "new", @name], chdir: @projects)
      assert!(made.stdout.includes?("Created #{@name}."), made.stdout)
      configured = "#{@name} is configured at https://#{@name}.caramel"
      assert!(made.stdout.includes?(configured), made.stdout)
    end

    # Copies the fixture files at *relative* paths into the project, in the
    # application's layout. A `config/routes.cr` fixture holds only the routes
    # the page adds; they go in before Frappé's resource routes.
    def copy(relative : Array(String)) : Nil
      relative.each do |path|
        source = File.join(@fixture, path)
        assert!(File.exists?(source), "No fixture file #{source}")
        target = File.join(@project, path)
        if path == "config/routes.cr"
          generated = File.read(target)
          assert!(generated.includes?(RESOURCE_ROUTES), generated)
          File.write(target, generated.sub(RESOURCE_ROUTES, File.read(source) + RESOURCE_ROUTES))
        else
          Dir.mkdir_p(File.dirname(target))
          File.write(target, File.read(source))
        end
      end
    end

    # Every fixture file not yet copied, for a check that copies in one step.
    def fixture_files : Array(String)
      Dir.glob(File.join(@fixture, "**/*.cr")).map(&.lchop(@fixture + "/")).sort!
    end

    def frappe(*words : String, timeout : Time::Span = 300.seconds,
               echo : Bool = true) : Caramel::Latte::ProcessResult
      command([@frappe] + words.to_a, chdir: @project, timeout: timeout, echo: echo)
    end

    # `frappe db diff --name NAME`, returning the one migration it wrote.
    def diff(name : String) : String
      pattern = File.join(@project, "db/migrations/*.cr")
      before = Dir.glob(pattern)
      written = frappe("db", "diff", "--name", name)
      assert!(written.stdout.includes?("Wrote "), written.stdout)
      derived = Dir.glob(pattern) - before
      assert!(derived.size == 1 && derived.first.ends_with?("_#{name}.cr"), derived.inspect)
      File.read(derived.first)
    end

    # `frappe migrate`, asserting it applied *count* migrations and matched.
    def migrate(count : Int32) : Nil
      migrated = frappe("migrate")
      assert!(migrated.stdout.includes?("Applied #{count} migrations."), migrated.stdout)
      assert!(migrated.stdout.includes?(MATCHED), migrated.stdout)
    end

    # `frappe routes FILTER`, asserting each expected line word for word.
    def routes(filter : String, expected : Array(String)) : Nil
      listed = frappe("routes", filter, echo: false).stdout
      expected.each do |route|
        assert!(listed.lines.any? { |line| line.split == route.split }, listed)
      end
    end

    # `frappe corretto`, asserting every example passed on one worker.
    def corretto(paths : Array(String) = [] of String) : Nil
      result = command([@frappe, "corretto"] + paths, chdir: @project, timeout: 600.seconds)
      ran = result.stdout.includes?("examples, 0 failures")
      passed = result.stdout.includes?("Corretto: 1 of 1 workers passed")
      assert!(ran && passed, result.stdout + result.stderr)
    end

    # The page's proof: `frappe check`, `frappe corretto` and `frappe lint`.
    def prove : Nil
      frappe("check", timeout: 600.seconds)
      corretto
      frappe("lint")
    end

    # Serves the built application and returns the body at *path*, or the
    # status code as text when *status_only*.
    def fetch(path : String, status_only : Bool = false) : String
      serve(@project, @name, local_values(@project)) unless @app
      port = @ports[2]
      curl = ["/usr/bin/curl", "--silent", "--show-error",
              "--max-time", "5", "--noproxy", "*", "--cacert", certificate,
              "--resolve", "#{@name}.caramel:#{port}:127.0.0.1",
              "-H", "Host: #{@name}.caramel"]
      url = "https://#{@name}.caramel:#{port}#{path}"
      if status_only
        attempt(curl + ["-o", "/dev/null", "-w", "%{http_code}", url]).stdout
      else
        command(curl + ["--fail", url], echo: false).stdout
      end
    end
  end
end
