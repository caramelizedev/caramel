# What SweetTalk lets a model say without a type-code switch: a closed-set string value
# with its members as methods, and optional attributes of every stored kind, in an
# aggregate, an entity, a projection and a process, kept in nullable columns that PostgreSQL
# also holds to their values' checks and, for a value with parts, to all or none; and events
# that carry attributes by name.
require "./support/app"

module ExpressiveModelsSpec
  alias Counter = Ledger::Counter

  def self.money(cents : Int64, currency : String = "USD") : Counter::Money
    Counter::Money.new(currency: Counter::Currency.new(currency), cents: Counter::Cents.new(cents))
  end

  def self.teller(text : String) : Counter::Teller
    Counter::Teller.new(text)
  end

  def self.transfer(kind : String = "payment", opened_by : String = "Ada",
                    cents : Int64 = 500_i64) : Counter::Transfer
    Counter::Transfer.create(kind: Counter::Kind.new(kind), amount: money(cents),
      opened_by: teller(opened_by))
  end

  # The name of the check that keeps an optional value of Money's parts all set or all nil.
  def self.all_or_none(table : String, attribute : String) : String
    "check_#{table}_#{attribute}_#{Counter::Money::SWEETTALK_OPTIONAL_CHECK[0]}"
  end

  # Runs *sql* in its own savepoint and returns the check it broke.
  def self.broken(sql : String, *args) : String?
    SugarORM::Repo.transaction { SugarORM.sql_exec(sql, *args) }
    nil
  rescue error : SugarORM::CheckViolation
    error.constraint
  end

  # A batch opened by Ada with one slip per label.
  def self.batch(*labels : String) : Counter::Batch
    slips = labels.map { |label| Counter::Batch::Slip.new(label: label) }.to_a
    Counter::Batch.open(teller("Ada"), slips)
  end

  # How many statements the block sent.
  def self.statements(&) : Int64
    before = SugarORM::Repo.statements_executed
    yield
    SugarORM::Repo.statements_executed - before
  end
end

describe "SweetTalk's closed-set values" do
  it "lists its members once, and gives each a constructor and a predicate" do
    Ledger::Counter::Kind.all.map(&.raw).should eq(%w[payment receipt net_settlement])
    kind = Ledger::Counter::Kind.receipt
    kind.raw.should eq("receipt")
    kind.receipt?.should be_true
    kind.payment?.should be_false
    Ledger::Counter::Kind.net_settlement.net_settlement?.should be_true
    Ledger::Counter::Kind.includes?("payment").should be_true
    Ledger::Counter::Kind.includes?("refund").should be_false
  end

  it "refuses a text outside its list, naming the list" do
    expect_raises(SweetTalk::Refusal, "Kind must be one of payment, receipt, net_settlement") do
      Ledger::Counter::Kind.new("refund")
    end
    expect_raises(SweetTalk::Refusal, "Currency must be one of USD, EUR, UZS") do
      Ledger::Counter::Currency.new("usd")
    end
  end

  it "compares and sorts as text, and builds a contract field or its message" do
    (Ledger::Counter::Kind.payment < Ledger::Counter::Kind.receipt).should be_true
    Ledger::Counter::Kind.from_field("receipt") { |_| fail "no refusal expected" }
      .try(&.receipt?).should be_true
    refusal = nil
    Ledger::Counter::Kind.from_field("refund") { |message| refusal = message }
      .should be_nil
    refusal.should eq("Kind must be one of payment, receipt, net_settlement")
  end

  it "checks the list in PostgreSQL, under a name that changes with the list" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer
      ExpressiveModelsSpec.broken("UPDATE counter_transfers SET kind = 'refund' WHERE id = $1",
        transfer.id.raw).to_s.should start_with("check_counter_transfers_kind_one_of_")
      ExpressiveModelsSpec.broken("UPDATE counter_transfers SET kind = 'receipt' WHERE id = $1",
        transfer.id.raw).should be_nil
      Ledger::Counter::Transfer.find(transfer.id).kind.receipt?.should be_true
    end
  end
end

describe "SweetTalk's optional attributes" do
  it "starts every optional attribute as nil and stores it in a nullable column" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer
      transfer.owner.should be_nil
      transfer.account.should be_nil
      transfer.settled_by.should be_nil
      transfer.channel.should be_nil
      transfer.leg.should be_nil
      transfer.reason.should be_nil
      transfer.note.should be_nil
      stored = Ledger::Counter::Transfer.find(transfer.id)
      {stored.owner, stored.account, stored.settled_by, stored.channel, stored.leg, stored.reason,
       stored.note}.should eq({nil, nil, nil, nil, nil, nil, nil})
      row = SugarORM.sql(<<-SQL, as: {owner_id: Int64?, leg_currency: String?, leg_cents: Int64?})
        SELECT owner_id, leg_currency, leg_cents FROM counter_transfers
        SQL
      row.first.should eq({owner_id: nil, leg_currency: nil, leg_cents: nil})
    end
  end

  it "derives a nullable column for each optional attribute, and a key and index for a reference" do
    SweetTalkSpec.rolled_back do
      columns = SugarORM.sql(<<-SQL, as: {name: String, nullable: String})
        SELECT column_name AS name, is_nullable AS nullable FROM information_schema.columns
        WHERE table_name = 'counter_transfers'
          AND column_name NOT IN ('id', 'created_at', 'updated_at')
        ORDER BY column_name
        SQL
      nullable = columns.select { |column| column[:nullable] == "YES" }.map(&.[:name])
      nullable.should eq(%w[account_id channel leg_cents leg_currency note owner_id reason
        removed_at settled_by])
      keys = SugarORM.sql(<<-SQL, as: {name: String, target: String})
        SELECT conname AS name, confrelid::regclass::text AS target FROM pg_constraint
        WHERE conrelid = 'counter_transfers'::regclass AND contype = 'f'
        SQL
      keys.map(&.[:target]).sort!.should eq(%w[counter_owners ledger_accounts])
      indexes = SugarORM.sql(<<-SQL, as: {name: String})
        SELECT indexname AS name FROM pg_indexes WHERE tablename = 'counter_transfers'
        SQL
      indexes.map(&.[:name]).should contain("index_counter_transfers_on_owner_id")
      indexes.map(&.[:name]).should contain("index_counter_transfers_on_account_id")
    end
  end

  it "stores an optional reference as an id, and clears it" do
    SweetTalkSpec.rolled_back do
      owner = Ledger::Counter::Owner.create(name: "Ada")
      transfer = ExpressiveModelsSpec.transfer
      transfer.assign(owner)
      transfer.owner.should eq(owner.id)
      Ledger::Counter::Transfer.find(transfer.id).owner.should eq(owner.id)
      Ledger::Counter::Transfer.unassigned.should be_empty
      transfer.leave_unassigned
      Ledger::Counter::Transfer.find(transfer.id).owner.should be_nil
      Ledger::Counter::Transfer.unassigned.map(&.id).should eq([transfer.id])
    end
  end

  it "takes an optional reference given as an aggregate or an id at creation" do
    SweetTalkSpec.rolled_back do
      owner = Ledger::Counter::Owner.create(name: "Ada")
      amount = ExpressiveModelsSpec.money(5_i64)
      opened_by = ExpressiveModelsSpec.teller("Ada")
      kind = Ledger::Counter::Kind.payment
      by_aggregate = Ledger::Counter::Transfer.create(kind: kind, amount: amount,
        opened_by: opened_by, owner: owner)
      by_id = Ledger::Counter::Transfer.create(kind: kind, amount: amount, opened_by: opened_by,
        owner: owner.id)
      explicit_nil = Ledger::Counter::Transfer.create(kind: kind, amount: amount,
        opened_by: opened_by, owner: nil)
      {by_aggregate.owner, by_id.owner, explicit_nil.owner}.should eq({owner.id, owner.id, nil})
    end
  end

  it "stores an optional reference to the application's own record, and clears it" do
    SweetTalkSpec.rolled_back do
      account = Ledger::Account.create!(email: "ada@example.com")
      transfer = ExpressiveModelsSpec.transfer
      transfer.use_account(account)
      expected = SweetTalk::RecordId(Ledger::Account).new(account.id)
      transfer.account.should eq(expected)
      Ledger::Counter::Transfer.find(transfer.id).account.should eq(expected)
      transfer.use_account(nil)
      Ledger::Counter::Transfer.find(transfer.id).account.should be_nil
      with_record = Ledger::Counter::Transfer.create(kind: Ledger::Counter::Kind.payment,
        amount: ExpressiveModelsSpec.money(1_i64), opened_by: ExpressiveModelsSpec.teller("Ada"),
        account: account)
      with_record.account.should eq(expected)
    end
  end

  it "stores an optional value as its raw, and refuses it as a value does" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer(opened_by: "Ada")
      expect_raises(SweetTalk::Refusal, "A teller does not settle what they opened.") do
        transfer.settle(ExpressiveModelsSpec.teller("Ada"))
      end
      transfer.settled_by.should be_nil
      expect_raises(SweetTalk::Refusal, "Teller must be between 2 and 20 characters") do
        ExpressiveModelsSpec.teller("B")
      end
      transfer.settle(ExpressiveModelsSpec.teller("Bo"))
      Ledger::Counter::Transfer.find(transfer.id).settled_by
        .should eq(ExpressiveModelsSpec.teller("Bo"))
      other = ExpressiveModelsSpec.transfer
      other.undo(Ledger::Counter::Reason.new("returned"))
      Ledger::Counter::Transfer.find(other.id).reason.try(&.raw).should eq("returned")
      ExpressiveModelsSpec.broken("UPDATE counter_transfers SET reason = 'no' WHERE id = $1",
        other.id.raw).should eq("check_counter_transfers_reason_length_3_40")
      ExpressiveModelsSpec.broken("UPDATE counter_transfers SET reason = NULL WHERE id = $1",
        other.id.raw).should be_nil
    end
  end

  it "stores an optional closed-set value, which PostgreSQL holds to its list or to null" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer
      Ledger::Counter::Transfer.without_channel.map(&.id).should eq([transfer.id])
      transfer.arrive_by(Ledger::Counter::Channel.new("post"))
      Ledger::Counter::Transfer.find(transfer.id).channel.try(&.post?).should be_true
      Ledger::Counter::Transfer.without_channel.should be_empty
      ExpressiveModelsSpec.broken("UPDATE counter_transfers SET channel = 'fax' WHERE id = $1",
        transfer.id.raw).to_s.should start_with("check_counter_transfers_channel_one_of_")
      transfer.arrive_by(nil)
      Ledger::Counter::Transfer.find(transfer.id).channel.should be_nil
    end
  end

  it "stores an optional value with parts in nullable columns, and builds it again" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer
      leg = ExpressiveModelsSpec.money(250_i64, "EUR")
      transfer.give_back(leg)
      stored = Ledger::Counter::Transfer.find(transfer.id)
      stored.leg.should eq(leg)
      stored.leg.try(&.currency.raw).should eq("EUR")
      columns = SugarORM.sql("SELECT leg_currency, leg_cents FROM counter_transfers WHERE id = $1",
        transfer.id.raw, as: {leg_currency: String?, leg_cents: Int64?})
      columns.first.should eq({leg_currency: "EUR", leg_cents: 250_i64})
    end
  end

  it "has PostgreSQL refuse a half-set value with parts written around the domain" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer
      all_or_none = ExpressiveModelsSpec.all_or_none("counter_transfers", "leg")
      ExpressiveModelsSpec.broken("UPDATE counter_transfers SET leg_currency = 'EUR' WHERE id = $1",
        transfer.id.raw).should eq(all_or_none)
      transfer.give_back(ExpressiveModelsSpec.money(1_i64))
      ExpressiveModelsSpec.broken("UPDATE counter_transfers SET leg_cents = NULL WHERE id = $1",
        transfer.id.raw).should eq(all_or_none)
      Ledger::Counter::Transfer.find(transfer.id).leg.try(&.cents.raw).should eq(1)
      ExpressiveModelsSpec.broken(
        "UPDATE counter_transfers SET leg_currency = NULL, leg_cents = NULL WHERE id = $1",
        transfer.id.raw).should be_nil
      Ledger::Counter::Transfer.find(transfer.id).leg.should be_nil
    end
  end

  it "refuses a half-set value with parts when its columns are read, as a loaded row would be" do
    # The function a load runs on the part columns, called with what such a row holds.
    money = Ledger::Counter::Money
    money.__sweettalk_from_columns(currency: nil, cents: nil).should be_nil
    money.__sweettalk_from_columns(currency: "EUR", cents: 7_i64)
      .should eq(ExpressiveModelsSpec.money(7_i64, "EUR"))
    half = "Money must have all of its parts or none: currency, cents"
    expect_raises(SweetTalk::Refusal, half) do
      money.__sweettalk_from_columns(currency: "EUR", cents: nil)
    end
    expect_raises(SweetTalk::Refusal, half) do
      money.__sweettalk_from_columns(currency: nil, cents: 7_i64)
    end
    expect_raises(SweetTalk::Refusal, "Currency must be one of USD, EUR, UZS") do
      money.__sweettalk_from_columns(currency: "GBP", cents: 7_i64)
    end
  end

  it "refuses to load a half-set value with parts that reached the table without its check" do
    # The owner drops the CHECK, so a row only PostgreSQL would have stopped can be read back.
    owner = SweetTalkSpec.owner
    all_or_none = ExpressiveModelsSpec.all_or_none("counter_transfers", "leg")
    definition = owner.query_one(
      "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
      all_or_none, as: String)
    SweetTalkSpec.committed do
      owner.exec(%(ALTER TABLE counter_transfers DROP CONSTRAINT "#{all_or_none}"))
      begin
        transfer = ExpressiveModelsSpec.transfer
        owner.exec("UPDATE counter_transfers SET leg_currency = 'EUR' WHERE id = $1",
          transfer.id.raw)
        expect_raises(SweetTalk::Refusal, "Money must have all of its parts or none") do
          Ledger::Counter::Transfer.find(transfer.id)
        end
        expect_raises(SweetTalk::Refusal, "Money must have all of its parts or none") do
          Ledger::Counter::Transfer.all
        end
      ensure
        owner.exec("UPDATE counter_transfers SET leg_currency = NULL")
        owner.exec(%(ALTER TABLE counter_transfers ADD CONSTRAINT "#{all_or_none}" #{definition}))
      end
    end
  end

  it "holds the parts of an optional value to their own checks" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer
      expect_raises(SweetTalk::Refusal, "Currency must be one of USD, EUR, UZS") do
        ExpressiveModelsSpec.money(5_i64, "GBP")
      end
      ExpressiveModelsSpec.broken(
        "UPDATE counter_transfers SET leg_currency = 'GBP', leg_cents = 1 WHERE id = $1",
        transfer.id.raw).to_s.should start_with("check_counter_transfers_leg_currency_one_of_")
      ExpressiveModelsSpec.broken(
        "UPDATE counter_transfers SET leg_currency = 'USD', leg_cents = -1 WHERE id = $1",
        transfer.id.raw).should eq("check_counter_transfers_leg_cents")
    end
  end

  it "reads an optional attribute in finds, counts and specifications, in Crystal and PostgreSQL" do
    SweetTalkSpec.rolled_back do
      owner = Ledger::Counter::Owner.create(name: "Ada")
      plain = ExpressiveModelsSpec.transfer("payment", "Ada")
      legged = ExpressiveModelsSpec.transfer("receipt", "Cy")
      legged.give_back(ExpressiveModelsSpec.money(9_i64))
      settled = ExpressiveModelsSpec.transfer("receipt", "Ada")
      settled.settle(ExpressiveModelsSpec.teller("Bo"))
      settled.assign(owner)
      Ledger::Counter::Transfer.without_leg.map(&.id).should eq([plain.id, settled.id])
      Ledger::Counter::Transfer.unassigned.map(&.id).should eq([plain.id, legged.id])
      Ledger::Counter::Transfer.of_kind(Ledger::Counter::Kind.receipt).map(&.id)
        .should eq([legged.id, settled.id])
      Ledger::Counter::Transfer.opened_by_teller(ExpressiveModelsSpec.teller("Ada")).map(&.id)
        .should eq([plain.id, settled.id])
      Ledger::Counter::Transfer.settled_unattended.should eq(0)
      all = Ledger::Counter::Transfer.all
      Ledger::Counter::Transfer.all(satisfying: Ledger::Counter::Unsettled).map(&.id)
        .should eq([plain.id, legged.id])
      all.select { |transfer| Ledger::Counter::Unsettled.satisfied_by?(transfer) }.map(&.id)
        .should eq([plain.id, legged.id])
      Ledger::Counter::Transfer.all(satisfying: Ledger::Counter::Unlegged).map(&.id)
        .should eq([plain.id, settled.id])
      all.select { |transfer| Ledger::Counter::Unlegged.satisfied_by?(transfer) }.map(&.id)
        .should eq([plain.id, settled.id])
      Ledger::Counter::Transfer.all(satisfying: Ledger::Counter::Receipts).map(&.id)
        .should eq([legged.id, settled.id])
      all.select { |transfer| Ledger::Counter::Receipts.satisfied_by?(transfer) }.map(&.id)
        .should eq([legged.id, settled.id])
    end
  end

  it "sorts the rows with no value first in descending order and last in ascending order" do
    SweetTalkSpec.rolled_back do
      first = ExpressiveModelsSpec.transfer
      middle = ExpressiveModelsSpec.transfer
      last = ExpressiveModelsSpec.transfer
      first.undo(Ledger::Counter::Reason.new("alpha"))
      last.undo(Ledger::Counter::Reason.new("gamma"))
      Ledger::Counter::Transfer.by_reason_desc.map(&.id).should eq([middle.id, last.id, first.id])
      Ledger::Counter::Transfer.by_reason_asc.map(&.id).should eq([first.id, last.id, middle.id])
    end
  end

  it "keeps optional attributes in an entity, with their columns, checks and facts" do
    SweetTalkSpec.rolled_back do
      owner = Ledger::Counter::Owner.create(name: "Ada")
      transfer = ExpressiveModelsSpec.transfer
      transfer.pay_line("fee", nil, nil, nil)
      transfer.pay_line("salary", owner, ExpressiveModelsSpec.teller("Cy"),
        ExpressiveModelsSpec.money(40_i64, "UZS"))
      lines = Ledger::Counter::Transfer.find(transfer.id).lines
      lines.map(&.label).should eq(%w[fee salary])
      lines[0].payee.should be_nil
      lines[0].paid_by.should be_nil
      lines[0].share.should be_nil
      lines[1].payee.should eq(owner.id)
      lines[1].paid_by.try(&.raw).should eq("Cy")
      lines[1].share.try(&.currency.raw).should eq("UZS")
      all_or_none = ExpressiveModelsSpec.all_or_none("counter_transfer_lines", "share")
      ExpressiveModelsSpec.broken(
        "UPDATE counter_transfer_lines SET share_cents = NULL WHERE label = 'salary'")
        .should eq(all_or_none)
    end
  end

  it "builds by a factory an aggregate whose optional attributes come before a required one" do
    SweetTalkSpec.rolled_back do
      issuer = ExpressiveModelsSpec.teller("Ada")
      kind = Ledger::Counter::Kind.receipt
      by_position = Ledger::Counter::Voucher.issue(issuer, kind)
      by_name = Ledger::Counter::Voucher.issue(kind: kind, issuer: issuer)
      [by_position, by_name].each do |voucher|
        stored = Ledger::Counter::Voucher.find(voucher.id)
        {stored.remark, stored.owner, stored.issuer, stored.kind}
          .should eq({nil, nil, issuer, kind})
      end
      by_position.remark_on("for the desk")
      Ledger::Counter::Voucher.find(by_position.id).remark.should eq("for the desk")
    end
  end
end

describe "SweetTalk's events that carry attributes" do
  it "takes the carried fields from the aggregate, and hands them to a handler as emitted" do
    SweetTalkSpec.rolled_back do |connection|
      Ledger::Counter.settlements.clear
      Ledger::Counter.undoings.clear
      owner = Ledger::Counter::Owner.create(name: "Ada")
      transfer = ExpressiveModelsSpec.transfer("receipt", "Ada", 700_i64)
      transfer.assign(owner)
      transfer.give_back(ExpressiveModelsSpec.money(9_i64, "EUR"))
      transfer.pay_line("fee", nil, nil, nil)
      transfer.settle(ExpressiveModelsSpec.teller("Bo"))
      transfer.undo(nil)
      Caramel::ColdBrew.drain_queue(connection).should eq(4)
      Ledger::Counter.settlements.should eq(
        ["receipt|700|Ada|#{owner.id.raw}|Bo|EUR9|fee|1"])
      Ledger::Counter.undoings.should eq(["#{owner.id.raw}||undone by the desk"])
    end
  end

  it "carries an unset optional attribute as nil" do
    SweetTalkSpec.rolled_back do |connection|
      Ledger::Counter.settlements.clear
      transfer = ExpressiveModelsSpec.transfer
      transfer.settle(ExpressiveModelsSpec.teller("Bo"))
      Caramel::ColdBrew.drain_queue(connection).should eq(3)
      Ledger::Counter.settlements.should eq(["payment|500|Ada||Bo|||0"])
    end
  end

  it "reads a field of a queued event that did not exist when it was queued as nil if optional" do
    meta = %({"id":"e1","at":"2026-03-01T00:00:00.000000Z","by":null,"cause":null,"flow":"f1"})
    undone = Ledger::Counter::Transfer::Undone
    queued_before = undone.__sweettalk_load(7_i64, %({"note":"older"}), meta)
    queued_before.note.should eq("older")
    queued_before.owner.should be_nil
    queued_before.reason.should be_nil
    expect_raises(KeyError) { undone.__sweettalk_load(7_i64, %({"owner":null}), meta) }
  end

  it "keeps optional attributes in a projection a handler fills from carried fields" do
    SweetTalkSpec.rolled_back do |connection|
      owner = Ledger::Counter::Owner.create(name: "Ada")
      other = Ledger::Counter::Owner.create(name: "Bo")
      first = ExpressiveModelsSpec.transfer
      first.assign(owner)
      first.give_back(ExpressiveModelsSpec.money(7_i64, "UZS"))
      first.settle(ExpressiveModelsSpec.teller("Cy"))
      second = ExpressiveModelsSpec.transfer
      second.assign(other)
      second.settle(ExpressiveModelsSpec.teller("Di"))
      Caramel::ColdBrew.drain_queue(connection).should eq(6)
      standings = Ledger::Counter::Standing.all
      standings.map(&.last_settled_by.try(&.raw)).should eq(%w[Cy Di])
      standings.map(&.last_leg.try(&.cents.raw)).should eq([7_i64, nil])
      standings.map(&.last_transfer).should eq([first.id, second.id])
      Ledger::Counter::Standing.without_leg.map(&.last_settled_by.try(&.raw)).should eq(%w[Di])
      followups = Ledger::Counter::Followup.all
      followups.map(&.followed_by.try(&.raw)).should eq(%w[Cy Di])
      followups.map(&.followed_with.try(&.cents.raw)).should eq([7_i64, nil])
      followups.map(&.followed_owner).should eq([owner.id, other.id])
    end
  end
end

describe "SweetTalk's entities" do
  it "builds an entity by name, leaving out a defaulted attribute declared before a required one" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer
      transfer.pay_line("fee", nil, nil, nil)
      line = Ledger::Counter::Transfer.find(transfer.id).lines.first
      {line.memo, line.label}.should eq({"", "fee"})
      by_position = Ledger::Counter::Transfer::Line.new("for the desk", "salary")
      {by_position.memo, by_position.label}.should eq({"for the desk", "salary"})
    end
  end

  it "refuses a command that leaves an entity's never true, and saves nothing" do
    SweetTalkSpec.rolled_back do
      transfer = ExpressiveModelsSpec.transfer
      expect_raises(SweetTalk::Refusal, "A line names what it pays.") do
        transfer.pay_line(" ", nil, nil, nil)
      end
      Ledger::Counter::Transfer.find(transfer.id).lines.should be_empty
    end
  end

  it "reads created_at and updated_at from the row, and moves updated_at only on a change" do
    SweetTalkSpec.committed do
      Ledger::Counter::Transfer::Line.new("", "fee").created_at.should be_nil
      owner = Ledger::Counter::Owner.create(name: "Ada")
      transfer = ExpressiveModelsSpec.transfer
      created = transfer.created_at.not_nil!
      transfer.updated_at.should eq(created)
      transfer.leave_unassigned
      Ledger::Counter::Transfer.find(transfer.id).updated_at.should eq(created)
      transfer.assign(owner)
      transfer.updated_at.not_nil!.should be > created
      Ledger::Counter::Transfer.find(transfer.id).updated_at.should eq(transfer.updated_at)
      transfer.pay_line("fee", nil, nil, nil)
      line = transfer.lines.first
      line.created_at.should eq(line.updated_at)
      transfer.leave_unassigned
      Ledger::Counter::Transfer.find(transfer.id).lines.first.updated_at.should eq(line.updated_at)
    end
  end

  it "follows an optional reference to the aggregate's own type" do
    SweetTalkSpec.rolled_back do
      amount = Ledger::Counter::Cents.new(9_i64)
      original = Ledger::Counter::Entry.create(amount: amount)
      reversal = Ledger::Counter::Entry.create(amount: amount)
      reversal.reverse(original)
      reloaded = Ledger::Counter::Entry.find(reversal.id)
      reloaded.reversal_of.should eq(original.id)
      Ledger::Counter::Entry.find(reloaded.reversal_of.not_nil!).reversal_of.should be_nil
      keys = SugarORM.sql(<<-SQL, as: {target: String})
        SELECT confrelid::regclass::text AS target FROM pg_constraint
        WHERE conrelid = 'counter_entries'::regclass AND contype = 'f'
        SQL
      keys.map(&.[:target]).should eq(%w[counter_entries])
    end
  end
end

describe "SweetTalk's entities when an aggregate is saved" do
  it "writes one UPDATE for the entity a command changed, and nothing for the rest" do
    SweetTalkSpec.rolled_back do
      batch = ExpressiveModelsSpec.batch("fee", "salary", "rent")
      ids = batch.slips.map(&.id)
      # The locked root, its slips, their marks, then the one slip that changed.
      ExpressiveModelsSpec.statements { batch.retitle("salary", "wages") }.should eq(4)
      # The three reads alone: neither the root nor a slip changed.
      ExpressiveModelsSpec.statements { batch.retitle("wages", "wages") }.should eq(3)
      reloaded = Ledger::Counter::Batch.find(batch.id)
      reloaded.slips.map(&.label).should eq(%w[fee wages rent])
      reloaded.slips.map(&.id).should eq(ids)
    end
  end

  it "deletes only the entity rows a command dropped, one statement per list per level" do
    SweetTalkSpec.rolled_back do
      batch = ExpressiveModelsSpec.batch("fee", "salary", "rent")
      ids = batch.slips.map(&.id)
      # The locked root, its slips, their marks, then one DELETE of the struck slip's marks
      # and one of the slip.
      ExpressiveModelsSpec.statements { batch.strike("salary") }.should eq(5)
      Ledger::Counter::Batch.find(batch.id).slips.map(&.id).should eq([ids[0], ids[2]])
      SweetTalkSpec.count("counter_batch_slips").should eq(2)
    end
  end

  it "finds an aggregate without its entities in one statement, and a command on it loads them" do
    SweetTalkSpec.rolled_back do
      batch = ExpressiveModelsSpec.batch("fee", "salary")
      before = SugarORM::Repo.statements_executed
      found = Ledger::Counter::Batch.find(batch.id, entities: false)
      (SugarORM::Repo.statements_executed - before).should eq(1)
      found.opened_by.should eq(ExpressiveModelsSpec.teller("Ada"))
      message = "Batch #{batch.id} was found without its slips: find it with entities"
      expect_raises(SweetTalk::Unloaded, message) { found.slips }
      found.retitle("fee", "levy")
      found.slips.map(&.label).should eq(%w[levy salary])
      Ledger::Counter::Batch.find(batch.id).slips.map(&.label).should eq(%w[levy salary])
      Ledger::Counter::Batch.find?(batch.id, entities: false).should eq(batch)
    end
  end

  it "gives each entity in a factory's event the id its row got, in memory and in the job" do
    SweetTalkSpec.rolled_back do |connection|
      Ledger::Counter.openings.clear
      opened = SweetTalk.emitted(Ledger::Counter::Batch::Opened) do
        ExpressiveModelsSpec.batch("fee", "salary")
      end.first
      ids = opened.slips.map(&.id.raw)
      ids.size.should eq(2)
      fields = SugarORM.sql("SELECT payload->>'fields' AS fields FROM caramel_jobs",
        as: {fields: String})
      slips = JSON.parse(fields.first[:fields])["slips"].as_a
      slips.map(&.["id"].as_i64).should eq(ids)
      Caramel::ColdBrew.drain_queue(connection).should eq(1)
      Ledger::Counter.openings.should eq([ids])
      unsaved = Ledger::Counter::Batch::Slip.new(label: "rent")
      expect_raises(NilAssertionError, "Slip has no id until its aggregate is saved") { unsaved.id }
      queued_before = Ledger::Counter::Batch::Slip.new(fact: JSON.parse(%({"label":"rent"})))
      expect_raises(NilAssertionError, "Slip has no id until its aggregate is saved") do
        queued_before.id
      end
      # Queued before the slip held marks: the fact has no key for them.
      queued_before.marks.should be_empty
    end
  end

  it "loads, keeps and counts the entities an entity holds, one statement per list per level" do
    SweetTalkSpec.rolled_back do
      batch = ExpressiveModelsSpec.batch("A", "B")
      batch.mark("A", "x")
      batch.mark("A", "y")
      batch.mark("B", "z")
      found = nil
      # The root, its slips, then every mark of those slips at once.
      ExpressiveModelsSpec.statements { found = Ledger::Counter::Batch.find(batch.id) }.should eq(3)
      found.not_nil!.slips.map { |slip| slip.marks.map(&.note) }.should eq([%w[x y], %w[z]])
      SweetTalkSpec.count("counter_batch_slip_marks").should eq(3)
    end
  end

  it "deletes a dropped entity's own entities before it, one DELETE per list per level" do
    SweetTalkSpec.rolled_back do
      batch = ExpressiveModelsSpec.batch("A", "B")
      batch.mark("A", "x")
      batch.mark("A", "y")
      batch.mark("B", "z")
      batch.unmark("A", "x")
      Ledger::Counter::Batch.find(batch.id).slips.first.marks.map(&.note).should eq(["y"])
      SweetTalkSpec.count("counter_batch_slip_marks").should eq(2)
      # The root, its slips, their marks, then one DELETE of the slip's marks and one of the slip.
      ExpressiveModelsSpec.statements { batch.strike("A") }.should eq(5)
      SweetTalkSpec.count("counter_batch_slip_marks").should eq(1)
      SweetTalkSpec.count("counter_batch_slips").should eq(1)
    end
  end

  it "checks a nested entity's invariants with its aggregate's, and saves nothing on a refusal" do
    SweetTalkSpec.rolled_back do
      batch = ExpressiveModelsSpec.batch("A")
      batch.mark("A", "x")
      expect_raises(SweetTalk::Refusal, "A mark says something.") { batch.mark("A", "") }
      SweetTalkSpec.count("counter_batch_slip_marks").should eq(1)
    end
  end

  it "carries a nested entity in an event with the id its row got" do
    SweetTalkSpec.rolled_back do
      mark = Ledger::Counter::Batch::Slip::Mark.new("x")
      slip = Ledger::Counter::Batch::Slip.new("A", [mark])
      opened = SweetTalk.emitted(Ledger::Counter::Batch::Opened) do
        Ledger::Counter::Batch.open(ExpressiveModelsSpec.teller("Ada"), [slip])
      end.first
      carried = opened.slips.first.marks.first
      carried.note.should eq("x")
      carried.id.raw.should be > 0
      SweetTalkSpec.count("counter_batch_slip_marks").should eq(1)
    end
  end
end
