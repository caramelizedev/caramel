require "../spec_helper"
require "../support/ledger"

describe App::Ledger do
  it "adds up a period's posted lines" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post("2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post("2026-11", {"sales" => -100, "cash" => 100, "fees" => 7})
        LedgerSpec.draft("2026-11", {"fees" => 50})
        App::Ledger::Books::Journal.posted_in(LedgerSpec.period("2026-10")).raw.should eq(0)
        App::Ledger::Books::Journal.posted_in(LedgerSpec.period("2026-11")).raw.should eq(7)
        App::Ledger::Books::Journal.posted_in(LedgerSpec.period("2026-12")).raw.should eq(0)
      end
    end
  end

  it "groups a period's posted lines by heading" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post("2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post("2026-11", {"sales" => -100, "cash" => 100, "fees" => 7})
        LedgerSpec.draft("2026-11", {"fees" => 50})
        rows = App::Ledger::Books::Journal.by_heading_in(LedgerSpec.period("2026-11"))
        rows.map { |row| {row[:by].raw, row[:total].raw} }
          .should eq([{"cash", 100}, {"fees", 7}, {"sales", -100}])
      end
    end
  end

  it "groups for the bound tenant only" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post("2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post("2026-11", {"sales" => -100, "cash" => 100})
      end
      Caramel::Tenancy.with(account(db, "globex")) do
        LedgerSpec.post("2026-10", {"sales" => -9, "cash" => 9})
        rows = App::Ledger::Books::Journal.by_heading
        rows.map { |row| {row[:by].raw, row[:total].raw} }.should eq([{"cash", 9}, {"sales", -9}])
      end
    end
  end
end
