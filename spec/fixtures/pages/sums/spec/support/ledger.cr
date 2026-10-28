# Builders the ledger's specs share.
module LedgerSpec
  extend self

  def period(text : String) : App::Ledger::Books::Period
    App::Ledger::Books::Period.new(text)
  end

  def heading(text : String) : App::Ledger::Books::Heading
    App::Ledger::Books::Heading.new(text)
  end

  # Posts one journal of *amounts* by heading to *period*, and runs the
  # projection jobs it enqueued, so the balances are up to date when it returns.
  def post(db, period : String, amounts : Hash(String, Int32)) : Nil
    journal = App::Ledger::Books::Journal.open(self.period(period))
    amounts.each do |heading, amount|
      journal.add(heading(heading), App::Ledger::Books::Cents.new(amount))
    end
    journal.post
    Caramel::ColdBrew.drain_queue!(db)
  end
end
