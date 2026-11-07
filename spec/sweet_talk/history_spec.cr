# What SweetTalk keeps of how things came about (ADR 0056): `Books.reached(event)` walks
# every context's event log forward by cause, and a reference `pinned_at:` a state copies the
# aggregate it names when the state is entered, read only.
require "./support/app"

module HistorySpec
  alias Setup = Corrections::Setup
  alias Books = Corrections::Books
  alias Carry = Corrections::Carry

  # A journal opened under *rules*, its jobs drained, and the Opened event that began it.
  def self.opened(connection : DB::Connection,
                  rules : Setup::Rules) : {Books::Journal, Books::Journal::Opened}
    journals = [] of Books::Journal
    events = SweetTalk.emitted(Books::Journal::Opened) do
      journals << Books::Journal.open(100_i64, rules)
    end
    Caramel::ColdBrew.drain_queue(connection)
    {journals.first, events.first}
  end

  def self.rules(rate : Int64 = 5_i64) : Setup::Rules
    Setup::Rules.create(rate: rate, label: "base")
  end
end

describe "SweetTalk's reached events" do
  it "walks the events an event caused, across contexts, oldest first" do
    SweetTalkSpec.rolled_back do |connection|
      _journal, opened = HistorySpec.opened(connection, HistorySpec.rules)
      reached = HistorySpec::Books.reached(opened)
      reached.events.map(&.class.name).should eq([
        "Corrections::Carry::Batch::Started", "Corrections::Books::Noted",
      ])
      grouped = reached.by_subject
      grouped.keys.map(&.[0]).should eq(["Corrections::Carry::Batch", "Corrections::Books"])
      grouped.keys.map(&.[1].nil?).should eq([false, true])
      grouped.values.map(&.size).should eq([1, 1])
    end
  end

  it "leaves out the events of another chain" do
    SweetTalkSpec.rolled_back do |connection|
      rules = HistorySpec.rules
      _first, opened = HistorySpec.opened(connection, rules)
      HistorySpec.opened(connection, rules)
      HistorySpec::Books.reached(opened).events.size.should eq(2)
    end
  end

  it "refuses an event the log does not keep" do
    SweetTalkSpec.rolled_back do
      created = SweetTalk.emitted(HistorySpec::Setup::Rules::Created) { HistorySpec.rules }.first
      message = "Corrections::Setup::Rules::Created is not logged in books_events: " \
                "Books logs the events of books"
      expect_raises(ArgumentError, message) { HistorySpec::Books.reached(created) }
    end
  end
end

describe "SweetTalk's pinned references" do
  it "holds the rules as they were when the journal was sealed, and none before" do
    SweetTalkSpec.rolled_back do |connection|
      rules = HistorySpec.rules(5_i64)
      journal, _opened = HistorySpec.opened(connection, rules)
      journal.pinned_rules.should be_nil
      rules.reprice(7_i64)
      journal.seal
      rules.reprice(9_i64)
      pinned = Corrections::Books::Journal.find(journal.id).pinned_rules.not_nil!
      {pinned.rate, pinned.label}.should eq({7_i64, "base"})
      pinned.id.should eq(rules.id)
      Corrections::Setup::Rules.find(rules.id).rate.should eq(9_i64)
      journal.pinned_rules.not_nil!.rate.should eq(7_i64)
    end
  end

  it "refuses a command on a pinned copy" do
    SweetTalkSpec.rolled_back do |connection|
      rules = HistorySpec.rules
      journal, _opened = HistorySpec.opened(connection, rules)
      journal.seal
      pinned = journal.pinned_rules.not_nil!
      message = "Rules #{rules.id.raw} is a pinned copy, read only: find Rules #{rules.id.raw} " \
                "to change it"
      expect_raises(SweetTalk::Boundary, message) { pinned.reprice(1_i64) }
    end
  end
end
