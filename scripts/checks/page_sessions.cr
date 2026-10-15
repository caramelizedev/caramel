require "./support/page_fixture"

module Caramel::Checks
  # Follows the revocable sessions recipe (website page sessions) step by step.
  class PageSessions < PageFixture
    def initialize
      super("sessions", "clubhouse")
    end

    def proves : String
      "the revocable sessions recipe builds, migrates, routes and passes its specs"
    end

    def follow : Nil
      # 01 · Create the application and its tenant
      create
      tenancy = frappe("make", "tenancy", "Account")
      %w[app/models/account.cr app/actions/accounts/create.cr spec/requests/accounts_spec.cr
        config/routes.cr].each do |path|
        assert!(tenancy.stdout.includes?("Generated #{path}\n"), tenancy.stdout)
      end
      next_step = "Next: run frappe migrate and open /accounts/new."
      assert!(tenancy.stdout.includes?(next_step), tenancy.stdout)
      migrate(1)
      # 02 · Keep the revocable part in PostgreSQL
      copy(["app/models/user.cr", "app/models/user_session.cr", "app/models/membership.cr"])
      migration = diff("create_user_sessions")
      %w[users user_sessions memberships].each do |table|
        assert!(migration.includes?(%(CREATE TABLE "#{table}")), migration)
      end
      migrate(1)
      # 03 · Create the session at login, revoke it at logout; load it once per
      # request; guard tenant pages with ingress
      copy(["app/actions/sessions/new.cr", "app/actions/sessions/login.cr",
            "app/actions/sessions/logout.cr", "app/views/sessions/new.cr",
            "app/views/layouts/application.cr", "config/routes.cr",
            "app/actions/application_action.cr", "app/actions/accounts/home.cr",
            "app/actions/accounts/create.cr"])
      routes("login", [
        "GET /login App::Sessions::New",
        "POST /login App::Sessions::Login email:String password:String",
      ])
      routes("logout", ["POST /logout App::Sessions::Logout"])
      # 04 · Test the lifecycle in Corretto
      copy(["spec/support/sessions.cr", "spec/requests/sessions_spec.cr",
            "spec/requests/accounts_spec.cr"])
      # Prove it
      prove
    end
  end
end

begin
  Caramel::Checks::PageSessions.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
