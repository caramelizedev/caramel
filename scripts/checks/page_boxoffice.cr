require "./support/page_fixture"

module Caramel::Checks
  # Follows the Box Office path (website page boxoffice) step by step.
  class PageBoxoffice < PageFixture
    # What the seed prints when it schedules the show, with the show's address.
    SCHEDULED = %r{Scheduled The Tempest with 120 seats at (/shows/[0-9a-f-]{36})\.}

    def initialize
      super("boxoffice", "boxoffice")
    end

    def proves : String
      "the Box Office path builds, migrates, routes, seeds, serves and passes its specs"
    end

    def follow : Nil
      # 01 · Create the application and its domain
      create
      domain = frappe("make", "domain", "BoxOffice", "Seating",
        "--means=selling the seats of each show")
      %w[app/domain/box_office.cr spec/domain/box_office_spec.cr config/application.cr
        .claude/skills/sweettalk/SKILL.md].each do |path|
        assert!(domain.stdout.includes?("Generated #{path}\n"), domain.stdout)
      end
      next_step = "Next:\n  Write the domain in app/domain/box_office.cr.\n  " \
                  "frappe db diff --name create_box_office  derive its tables\n"
      assert!(domain.stdout.includes?(next_step), domain.stdout)
      # 02 to 05 · The domain, as one file, then frappe format and frappe check
      copy(["app/domain/box_office.cr"])
      frappe("format")
      check
      # 06 · Derive the tables
      migration = diff("create_box_office")
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
      migrate(1)
      # 07 · Let the show choose the buttons, then frappe check
      copy(["app/views/shows/show.cr", "app/views/holds/show.cr"])
      check
      # 08 · Answer guests from actions
      copy(["config/routes.cr", "app/actions/shows/show.cr", "app/actions/holds/create.cr",
            "app/actions/holds/show.cr", "app/actions/holds/sell.cr",
            "app/actions/waitlists/join.cr"])
      routes("shows", [
        "GET /shows/:show App::Shows::Show show:Show::Id(UUID)",
        "POST /shows/:show/holds App::Holds::Create show:Show::Id(UUID) " \
        "guest:Seating::Email(String) seats:Seating::Seats(Int32)",
        "GET /shows/:show/holds/:hold App::Holds::Show show:Show::Id(UUID) hold:Int32(min=1)",
        "POST /shows/:show/holds/:hold/sale App::Holds::Sell show:Show::Id(UUID) " \
        "hold:Int32(min=1)",
        "POST /shows/:show/waitlist App::Waitlists::Join show:Show::Id(UUID) " \
        "guest:Seating::Email(String) seats:Seating::Seats(Int32)",
      ])
      # 09 · Open the box office
      copy(["db/seeds.cr"])
      seeded = frappe("seed", timeout: 600.seconds).stdout
      path = seeded.match(SCHEDULED).try(&.[1]) || ""
      assert!(!path.empty?, seeded)
      second = frappe("seed", timeout: 600.seconds)
      assert!(!second.stdout.includes?("Scheduled The Tempest"), second.stdout)
      show = have_html {
        section(class: "show") {
          h1 { "The Tempest" }
          p { "120 of 120 seats left" }
          button(type: "submit") { "Hold seats" }
        }
      }
      page = fetch(path)
      assert!(show.match(page), show.failure_message(page))
      # An address that names no show answers 404.
      assert!(fetch("/shows/#{UUID.random}", status_only: true) == "404")
      # 10 · Specify the rules
      copy(["spec/support/box_office.cr", "spec/domain/box_office_spec.cr",
            "spec/requests/box_office_spec.cr"])
      corretto
      # Prove it
      prove
    end

    # `frappe check`, piped, prints `OK check N files`.
    private def check : Nil
      checked = frappe("check", timeout: 600.seconds)
      assert!(checked.stdout.includes?("OK check "), checked.stdout)
    end
  end
end

begin
  Caramel::Checks::PageBoxoffice.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
