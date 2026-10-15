require "./support/latte_fixture"
require "../../src/frappe/commands"
require "../../src/caramel"
require "../../src/caramel/corretto/matchers"
require "uri"
require "http/params"

module Caramel::Checks
  # Builds the application of the Box Office path (website page box-office)
  # from spec/fixtures/box_office with the page's own commands, then runs its
  # specs and fetches its page. website/check.mjs holds the page's snippets to
  # the same fixture files.
  class SweetTalkTutorial < LatteFixture
    include Corretto::Matchers
    getter project : String

    FIXTURE         = File.join(Checks::REPO, "spec/fixtures/box_office")
    MATCHED         = "The database matches the declared schema."
    RESOURCE_ROUTES = "    # Frappé resource routes"

    def initialize
      super("caramel-box-office-")
      @project = File.join(@projects, "boxoffice")
    end

    def execute(args : Array(String)) : Nil
      puts "Box Office fixture: #{@root}"
      # ameba:disable Lint/UselessAssign -- read by the ensure below
      failed = true
      begin
        start
        create
        copy_fixture
        command([@frappe, "check"], chdir: @project, timeout: 600.seconds)
        derive_tables
        migrated = command([@frappe, "migrate"], chdir: @project, timeout: 300.seconds)
        assert!(migrated.stdout.includes?("Applied 1 migrations."), migrated.stdout)
        assert!(migrated.stdout.includes?(MATCHED), migrated.stdout)
        routes
        corretto = command([@frappe, "corretto"], chdir: @project, timeout: 600.seconds)
        ran = corretto.stdout.includes?("examples, 0 failures")
        passed = corretto.stdout.includes?("Corretto: 1 of 1 workers passed")
        assert!(ran && passed, corretto.stdout + corretto.stderr)
        command([@frappe, "lint"], chdir: @project)
        seed
        fetch_pages
        puts "PASS: the Box Office path builds, migrates, routes, seeds, serves " \
             "and passes its specs"
        failed = false
      ensure
        finish(failed)
      end
    end

    # The path's first two commands: the application, then its domain.
    private def create : Nil
      made = command([@frappe, "new", "boxoffice"], chdir: @projects)
      assert!(made.stdout.includes?("Created boxoffice."), made.stdout)
      assert!(made.stdout.includes?("boxoffice is configured at https://boxoffice.caramel"),
        made.stdout)
      domain = command([@frappe, "make", "domain", "BoxOffice", "Seating",
                        "--means=selling the seats of each show"], chdir: @project)
      %w[app/domain/box_office.cr spec/domain/box_office_spec.cr config/application.cr
        .claude/skills/sweettalk/SKILL.md].each do |path|
        assert!(domain.stdout.includes?("Generated #{path}\n"), domain.stdout)
      end
      next_step = "Next: write the domain in app/domain/box_office.cr, " \
                  "then run frappe db diff --name create_box_office and frappe migrate."
      assert!(domain.stdout.includes?(next_step), domain.stdout)
    end

    # Writes the fixture's files over the project's; its routes join the
    # generated ones.
    private def copy_fixture : Nil
      Dir.glob(File.join(FIXTURE, "**/*.cr")).each do |source|
        relative = source.lchop(FIXTURE + "/")
        target = File.join(@project, relative)
        if relative == "config/routes.cr"
          generated = File.read(target)
          assert!(generated.includes?(RESOURCE_ROUTES), generated)
          File.write(target, generated.sub(RESOURCE_ROUTES, File.read(source) + RESOURCE_ROUTES))
        else
          Dir.mkdir_p(File.dirname(target))
          File.write(target, File.read(source))
        end
      end
    end

    # Derives the domain's tables, with the CHECK constraints its values state.
    private def derive_tables : Nil
      pattern = File.join(@project, "db/migrations/*.cr")
      before = Dir.glob(pattern)
      diff = command([@frappe, "db", "diff", "--name", "create_box_office"],
        chdir: @project, timeout: 300.seconds)
      assert!(diff.stdout.includes?("Wrote "), diff.stdout)
      derived = Dir.glob(pattern) - before
      assert!(derived.size == 1 && derived.first.ends_with?("_create_box_office.cr"),
        derived.inspect)
      migration = File.read(derived.first)
      %w[seating_shows seating_show_holds seating_show_tickets seating_checkouts
        waitlist_lines waitlist_line_guests].each do |table|
        assert!(migration.includes?(%(CREATE TABLE "#{table}")), migration)
      end
      ["CHECK (\"capacity\" >= 1 AND \"capacity\" <= 5000)",
       "CHECK (\"seats\" >= 1 AND \"seats\" <= 8)",
       "\"check_seating_show_holds_guest_length_3_254\"",
       "\"check_seating_shows_state_"].each do |text|
        assert!(migration.includes?(text), migration)
      end
    end

    private def routes : Nil
      listed = command([@frappe, "routes", "shows"], chdir: @project, echo: false).stdout
      expected = [
        "GET /shows/:show App::Shows::Show show:Show::Id(Int64)",
        "POST /shows/:show/holds App::Holds::Create show:Show::Id(Int64) " \
        "guest:Seating::Email(String) seats:Seating::Seats(Int32)",
        "GET /shows/:show/holds/:hold App::Holds::Show show:Show::Id(Int64) hold:Int32(min=1)",
        "POST /shows/:show/holds/:hold/sale App::Holds::Sell show:Show::Id(Int64) " \
        "hold:Int32(min=1)",
        "POST /shows/:show/waitlist App::Waitlists::Join show:Show::Id(Int64) " \
        "guest:Seating::Email(String) seats:Seating::Seats(Int32)",
      ]
      expected.each do |route|
        assert!(listed.lines.any? { |line| line.split == route.split }, listed)
      end
    end

    private def seed : Nil
      scheduled = "Scheduled The Tempest with 120 seats."
      first = command([@frappe, "seed"], chdir: @project, timeout: 600.seconds)
      assert!(first.stdout.includes?(scheduled), first.stdout)
      second = command([@frappe, "seed"], chdir: @project, timeout: 600.seconds)
      assert!(!second.stdout.includes?(scheduled), second.stdout)
    end

    private def fetch_pages : Nil
      values = local_values(@project)
      serve(@project, "boxoffice", values)
      port = @ports[2]
      curl = ["/usr/bin/curl", "--silent", "--show-error",
              "--max-time", "5", "--noproxy", "*", "--cacert", certificate,
              "--resolve", "boxoffice.caramel:#{port}:127.0.0.1",
              "-H", "Host: boxoffice.caramel"]
      url = "https://boxoffice.caramel:#{port}"
      page = command(curl + ["--fail", "#{url}/shows/1"], echo: false)
      show = have_html {
        section(class: "show") {
          h1 { "The Tempest" }
          p { "120 of 120 seats left" }
          button(type: "submit") { "Hold seats" }
        }
      }
      assert!(show.match(page.stdout), show.failure_message(page.stdout))
      # The second seed scheduled nothing, so there is no second show.
      missing = attempt(curl + ["-o", "/dev/null", "-w", "%{http_code}", "#{url}/shows/2"])
      assert!(missing.stdout == "404", missing.stdout + missing.stderr)
    end
  end
end

begin
  Caramel::Checks::SweetTalkTutorial.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
