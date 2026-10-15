require "./support/page_fixture"

module Caramel::Checks
  # Follows the signed webhook recipe (website page webhooks) step by step.
  class PageWebhooks < PageFixture
    SECRET = "WEBHOOK_SECRET=test-webhook-secret\n"

    def initialize
      super("webhooks", "ledger")
    end

    def proves : String
      "the signed webhook recipe routes, accepts a signed body, refuses forged, " \
      "unsigned and oversized ones, and passes frappe check, corretto and lint"
    end

    def follow : Nil
      # 01 · Create the application and give its specs a secret
      create
      File.open(File.join(@project, ".env.test"), "a", &.print(SECRET))
      # 02 · Route the inbox
      copy(["config/routes.cr"])
      # 03 · Verify before interpreting the body
      copy(["app/actions/hooks/inbox.cr"])
      # 04 · Read the route's policy
      routes("hooks", [
        "POST /hooks/inbox App::Hooks::Inbox [raw, 256 KiB, csrf off, authenticate signed?]",
      ])
      # 05 · Send exact bodies in Corretto
      copy(["spec/requests/hooks_spec.cr"])
      corretto
      # Prove it
      prove
    end
  end
end

begin
  Caramel::Checks::PageWebhooks.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
