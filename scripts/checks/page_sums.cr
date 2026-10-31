require "./support/page_fixture"

module Caramel::Checks
  # Follows the sums and groups recipe (website page sums) step by step.
  class PageSums < PageFixture
    def initialize
      super("sums", "ledger")
    end

    def proves : String
      "the sums and groups recipe adds up a period's posted lines, groups them by heading " \
      "for the bound tenant only, and passes frappe check, corretto and lint"
    end

    def follow : Nil
      # 01 · Create the application, its tenant and its domain
      create
      tenancy = frappe("make", "tenancy", "Account")
      assert!(tenancy.stdout.includes?("Generated app/models/account.cr\n"), tenancy.stdout)
      migrate(1)
      domain = frappe("make", "domain", "Ledger", "Books",
        "--means=what each heading was posted in each period")
      %w[app/domain/ledger.cr spec/domain/ledger_spec.cr].each do |path|
        assert!(domain.stdout.includes?("Generated #{path}\n"), domain.stdout)
      end
      # 02 · Declare the journal, its sums and its groups
      copy(["app/domain/ledger.cr"])
      migration = diff("create_ledger")
      %w[books_journals books_journal_lines].each do |table|
        assert!(migration.includes?(%(CREATE TABLE "#{table}")), migration)
      end
      migrate(1)
      # 03 · Specify the sums
      copy(["spec/support/ledger.cr", "spec/domain/ledger_spec.cr"])
      corretto(["spec/domain/ledger_spec.cr"])
      # Prove it
      prove
    end
  end
end

begin
  Caramel::Checks::PageSums.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
