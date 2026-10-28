require "./support/page_fixture"

module Caramel::Checks
  # Follows the sums and groups recipe (website page sums) step by step.
  class PageSums < PageFixture
    def initialize
      super("sums", "ledger")
    end

    def proves : String
      "the sums and groups recipe keeps one balance per heading and period, sums across " \
      "rows in Crystal, groups in SQL for the bound tenant only, and passes frappe check, " \
      "corretto and lint"
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
      # 02 · Keep the balance table as a projection
      copy(["app/domain/ledger.cr"])
      migration = diff("create_ledger")
      %w[books_journals books_journal_lines books_balances].each do |table|
        assert!(migration.includes?(%(CREATE TABLE "#{table}")), migration)
      end
      assert!(migration.includes?(%("slot_heading")), migration)
      assert!(migration.includes?(%("slot_period")), migration)
      migrate(1)
      # 03 · Group in SQL only with the tenant written out
      copy(["app/domain/ledger_reports.cr"])
      # 04 · Specify the sums
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
