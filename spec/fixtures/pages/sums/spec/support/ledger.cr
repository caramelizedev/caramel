# Builders the ledger's specs share.
module LedgerSpec
  extend self

  def period(text : String) : App::Ledger::Books::Period
    App::Ledger::Books::Period.new(text)
  end

  def heading(text : String) : App::Ledger::Books::Heading
    App::Ledger::Books::Heading.new(text)
  end

  # Opens one journal of *amounts* by heading to *period*, and leaves it open.
  def draft(period : String, amounts : Hash(String, Int32)) : Nil
    journal = App::Ledger::Books::Journal.open(self.period(period))
    amounts.each do |heading, amount|
      journal.add(heading(heading), App::Ledger::Books::Cents.new(amount))
    end
  end

  # Opens one journal of *amounts* by heading to *period*, and posts it.
  def post(period : String, amounts : Hash(String, Int32)) : Nil
    journal = App::Ledger::Books::Journal.open(self.period(period))
    amounts.each do |heading, amount|
      journal.add(heading(heading), App::Ledger::Books::Cents.new(amount))
    end
    journal.post
  end
end
