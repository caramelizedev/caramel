require "../spec_helper"
require "../support/ledger"

describe App::Ledger do
  it "keeps one balance per heading and period" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post(db, "2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post(db, "2026-10", {"sales" => -250, "cash" => 250})
        LedgerSpec.post(db, "2026-11", {"sales" => -100, "cash" => 100})
        rows = App::Ledger::Books::Balance.all
        rows.map { |row| {row.slot.heading.raw, row.slot.period.raw, row.total.raw, row.postings} }
          .should eq([{"sales", "2026-10", -750, 2}, {"cash", "2026-10", 750, 2},
                      {"sales", "2026-11", -100, 1}, {"cash", "2026-11", 100, 1}])
      end
    end
  end

  it "sums across headings in Crystal, over the rows a finds returns" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post(db, "2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post(db, "2026-11", {"sales" => -100, "cash" => 100, "fees" => 7})
        App::Ledger::Books.period_total(LedgerSpec.period("2026-10")).raw.should eq(0)
        App::Ledger::Books.period_total(LedgerSpec.period("2026-11")).raw.should eq(7)
        cash = App::Ledger::Books::Balance.for_heading(LedgerSpec.heading("cash"))
        cash.map { |row| {row.slot.period.raw, row.total.raw} }
          .should eq([{"2026-10", 500}, {"2026-11", 100}])
      end
    end
  end

  it "groups in SQL for the bound tenant only" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post(db, "2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post(db, "2026-11", {"sales" => -100, "cash" => 100})
      end
      Caramel::Tenancy.with(account(db, "globex")) do
        LedgerSpec.post(db, "2026-10", {"sales" => -9, "cash" => 9})
        App::Ledger::Reports.by_heading.should eq([{heading: "cash", total: 9_i64},
                                                   {heading: "sales", total: -9_i64}])
      end
    end
  end
end
