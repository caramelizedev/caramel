# The tea shop on PostgreSQL: commands, invariants, events that carry their facts, who
# acted, their cause and their flow, one aggregate per transaction, factories, queries,
# removal, string and composite values, a service, a process that holds stock, compensates
# and keeps a deadline, row locks, notifications and Cold Brew workers.
require "./support/app"

alias Catalogue = TeaShop::Catalogue
alias Ordering = TeaShop::Ordering
alias Fulfilment = TeaShop::Fulfilment

module TeaShopSpec
  CONTEXTS = %w[Catalogue Ordering Fulfilment]

  PLACED_BY_FULFILMENT    = "TeaShop::Fulfilment::OrderingBorder::WhenOrderingOrderPlaced"
  PLACED_BY_SALES         = "TeaShop::Ordering::Sales::WhenOrderPlaced"
  PLACED_BY_HOLD          = "TeaShop::Ordering::Hold::WhenOrderPlaced"
  CANCELLED_BY_HOLD       = "TeaShop::Ordering::Hold::WhenOrderCancelled"
  CANCELLED_BY_FULFILMENT = "TeaShop::Fulfilment::OrderingBorder::WhenOrderingOrderCancelled"
  DISPATCHED_BY_ORDERS    = "TeaShop::Ordering::FulfilmentBorder::WhenFulfilmentParcelDispatched"
  DISPATCHED_BY_HOLD      = "TeaShop::Ordering::Hold::WhenFulfilmentParcelDispatched"
  LAPSE                   = "TeaShop::Ordering::Hold::LapseDeadline"

  JOBS = <<-SQL
    SELECT class_name, failed_at IS NOT NULL AS failed, last_error
    FROM caramel_jobs ORDER BY id
    SQL
  FIELDS = <<-SQL
    SELECT payload->>'fields' AS fields FROM caramel_jobs WHERE class_name = $1 ORDER BY id
    SQL
  META = <<-SQL
    SELECT payload->>'meta' AS meta FROM caramel_jobs WHERE class_name = $1 ORDER BY id
    SQL
  PAYLOADS = <<-SQL
    SELECT payload->>'subject' AS subject, payload->>'fields' AS fields,
           payload->>'meta' AS meta
    FROM caramel_jobs WHERE class_name = $1 ORDER BY id
    SQL
  ADDRESSES = <<-SQL
    SELECT deliver_to_street, deliver_to_city, deliver_to_postcode FROM ordering_orders
    SQL

  def self.jobs : Array({class_name: String, failed: Bool, last_error: String?})
    SugarORM.sql(JOBS, as: {class_name: String, failed: Bool, last_error: String?})
  end

  # The facts each job of *class_name* carries, in the order they were enqueued.
  def self.fields(class_name : String) : Array(JSON::Any)
    SugarORM.sql(FIELDS, class_name, as: {fields: String}).map { |row| JSON.parse(row[:fields]) }
  end

  # The event metadata each job of *class_name* carries.
  def self.meta(class_name : String) : Array(JSON::Any)
    SugarORM.sql(META, class_name, as: {meta: String}).map { |row| JSON.parse(row[:meta]) }
  end

  def self.drain(connection, scheduled = false) : Int32
    Caramel::ColdBrew.drain_queue!(connection, include_scheduled: scheduled)
  end

  def self.tea(name : String, stock : Int32 = 5) : Catalogue::Tea
    price, tins = Catalogue::Cents.new(900), Catalogue::Tins.new(stock)
    Catalogue::Tea.create(name: name, price: price, stock: tins)
  end

  def self.account(email = "ada@example.com") : TeaShop::Account
    TeaShop::Account.create!(email: email)
  end

  def self.address(street = "1 Leaf Lane") : Ordering::Address
    postcode = Ordering::Postcode.new("CA1 1TE")
    Ordering::Address.new(street: street, city: "Camellia", postcode: postcode)
  end

  def self.order(*lines, member : TeaShop::Account = account) : Ordering::Order
    order = Ordering::Order.open(member, Ordering::Email.new("ada@example.com"), address)
    lines.each { |(tea, tins)| order.add tea, Ordering::Quantity.new(tins) }
    order
  end

  def self.parcel : Fulfilment::Parcel
    Fulfilment::Parcel.all.first
  end

  # Each hold's tea and state, sorted.
  def self.holds : Array({String, String})
    Ordering::Hold.all.map do |hold|
      tea = Catalogue::Tea.find(Catalogue::Tea::Id.new(hold.slot.tea))
      {tea.name, hold.state.to_s.downcase}
    end.sort!
  end
end

describe "The tea shop on PostgreSQL" do
  it "creates a tea and finds it again by its typed id" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      found = Catalogue::Tea.find(tea.id)
      shelf = {found.name, found.price.raw, found.stock.raw, found.held.raw}
      shelf.should eq({"Sencha", 900_i64, 5, 0})
      SugarORM.sql("SELECT stock FROM catalogue_teas", as: {stock: Int32}).should eq([{stock: 5}])
    end
  end

  it "raises NilAssertionError for an aggregate's id before create" do
    tea = Catalogue::Tea.new("Sencha", Catalogue::Cents.new(100), Catalogue::Tins.new(3))
    expect_raises(NilAssertionError, "Tea has no id until it is created") { tea.id }
  end

  it "refuses a value out of bounds before anything is written" do
    SweetTalkSpec.rolled_back do
      expect_raises(SweetTalk::Refusal, "Tins must be at least 0") { Catalogue::Tins.new(-1) }
      SweetTalkSpec.count("catalogue_teas").should eq(0)
    end
  end

  it "commits a command" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      tea.restock Catalogue::Tins.new(3)
      Catalogue::Tea.find(tea.id).stock.raw.should eq(8)
    end
  end

  it "times each command, factory and service as a domain span, and marks a refused one" do
    SweetTalkSpec.rolled_back do
      request = Caramel::Crema::Kind::Request
      trace = Caramel::Crema::Trace.new(request, "spec", "4bf92f3577b34da6a3ce929d0e0e4736",
        "00f067aa0ba902b7")
      trace.recording = true
      Caramel::Crema.bound(trace) do
        tea = TeaShopSpec.tea("Sencha")
        order = TeaShopSpec.order({tea, 2})
        order.place
        expect_raises(SweetTalk::Refusal) { order.add tea, Ordering::Quantity.new(1) }
        Ordering.requote(order.id)
      end
      domains = trace.spans.select(&.kind.domain?).map { |span| {span.name, span.error_class} }
      domains.should eq([
        {"Catalogue::Tea.create", nil},
        {"Ordering::Order.open", nil},
        {"Ordering::Order#add", nil},
        {"Ordering::Order#place", nil},
        {"Ordering::Order#add", "SweetTalk::Refusal"},
        {"Ordering.requote", nil},
      ])
      production = trace.to_event(Caramel::Crema::Detail::Production).spans
      production.select { |span| span.kind == "domain" }.map(&.detail).should eq([nil] * 6)
    end
  end

  it "rolls a refused command back, in the table and in memory" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      expect_raises(SweetTalk::Refusal, "Only 5 tins of Sencha free.") do
        tea.hold Catalogue::Tins.new(9)
      end
      tea.held.raw.should eq(0)
      Catalogue::Tea.find(tea.id).held.raw.should eq(0)
    end
  end

  it "rolls back a command that breaks an invariant, and enqueues nothing" do
    SweetTalkSpec.rolled_back do
      order = TeaShopSpec.order
      expect_raises(SweetTalk::Refusal, "An order needs at least one tea.") { order.place }
      order.open?.should be_true
      SweetTalkSpec.count("caramel_jobs").should eq(0)
    end
  end

  it "refuses a move the lifecycle does not allow" do
    SweetTalkSpec.rolled_back do
      order = TeaShopSpec.order
      expect_raises(SweetTalk::Refusal, "Order cannot become shipped while open") { order.ship }
    end
  end

  it "enqueues one job per policy, and one per line with each:, in the command's transaction" do
    SweetTalkSpec.rolled_back do
      sencha, gyokuro = TeaShopSpec.tea("Sencha"), TeaShopSpec.tea("Gyokuro")
      TeaShopSpec.order({sencha, 2}, {gyokuro, 1}).place
      expected = [
        TeaShopSpec::PLACED_BY_FULFILMENT, TeaShopSpec::PLACED_BY_HOLD, TeaShopSpec::PLACED_BY_HOLD,
        TeaShopSpec::PLACED_BY_SALES, TeaShopSpec::PLACED_BY_SALES,
      ]
      TeaShopSpec.jobs.map(&.[:class_name]).sort!.should eq(expected.sort)

      order = TeaShopSpec.order({sencha, 1})
      SugarORM::Repo.transaction do
        order.place
        SugarORM::Repo.rollback
      end
      SweetTalkSpec.count("caramel_jobs").should eq(5)
      Ordering::Order.find(order.id).open?.should be_true
    end
  end

  it "hands policies the facts as they were when the event was emitted" do
    SweetTalkSpec.rolled_back do |connection|
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      order.place
      line = Ordering::Rows::Order::Line.query.where(order_id: order.id.raw).first!
      SugarORM::Repo.update(Ordering::Rows::Order::Line::Changeset.new(line, quantity: 5))
      TeaShopSpec.drain(connection).should eq(3)

      Ordering::Sales.all.map { |row| {row.tea.raw, row.sold} }.should eq([{tea.id.raw, 2}])
      TeaShopSpec.parcel.packings.map(&.tins.raw).should eq([2])
      Catalogue::Tea.find(tea.id).held.raw.should eq(2)
    end
  end

  it "refuses a tea added after placement, and the same tea twice" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      placed = TeaShopSpec.order({tea, 2})
      placed.place
      message = "Teas can be added only while the order is open."
      expect_raises(SweetTalk::Refusal, message) { placed.add tea, Ordering::Quantity.new(5) }
      Ordering::Order.find(placed.id).lines.size.should eq(1)

      open = TeaShopSpec.order({tea, 2})
      expect_raises(SweetTalk::Refusal, "Sencha is already in this order.") do
        open.add tea, Ordering::Quantity.new(1)
      end
      Ordering::Order.find(open.id).lines.size.should eq(1)
    end
  end

  it "keeps the price a line was added at when the tea is repriced" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      tea.reprice Catalogue::Cents.new(1500)
      found = Ordering::Order.find(order.id)
      found.lines.map(&.price.raw).should eq([900_i64])
      found.total.raw.should eq(1800)
    end
  end

  it "holds stock at placement, takes it when the parcel leaves, and ships the order" do
    SweetTalkSpec.rolled_back do |connection|
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      order.place
      TeaShopSpec.drain(connection)
      held = Catalogue::Tea.find(tea.id)
      {held.held.raw, held.stock.raw}.should eq({2, 5})
      TeaShopSpec.holds.should eq([{"Sencha", "holding"}])

      TeaShopSpec.parcel.dispatch
      TeaShopSpec.drain(connection)
      taken = Catalogue::Tea.find(tea.id)
      {taken.held.raw, taken.stock.raw}.should eq({0, 3})
      Ordering::Order.find(order.id).shipped?.should be_true
      TeaShopSpec.holds.should eq([{"Sencha", "taken"}])
    end
  end

  it "cancels an order whose tea cannot be held, and releases what it held" do
    SweetTalkSpec.rolled_back do |connection|
      sencha, gyokuro = TeaShopSpec.tea("Sencha"), TeaShopSpec.tea("Gyokuro", 1)
      order = TeaShopSpec.order({sencha, 2}, {gyokuro, 2})
      order.place
      TeaShopSpec.drain(connection)

      Ordering::Order.find(order.id).cancelled?.should be_true
      reasons = TeaShopSpec.fields(TeaShopSpec::CANCELLED_BY_HOLD).map(&.["reason"]).uniq!
      reasons.should eq([JSON::Any.new("Only 1 tins of Gyokuro free.")])
      Catalogue::Tea.find(sencha.id).held.raw.should eq(0)
      TeaShopSpec.holds.should eq([{"Gyokuro", "refused"}, {"Sencha", "released"}])
      TeaShopSpec.parcel.withdrawn?.should be_true
      TeaShopSpec.jobs.count(&.[:failed]).should eq(0)
    end
  end

  it "cancels from open and from placed, and ships neither" do
    SweetTalkSpec.rolled_back do |connection|
      tea = TeaShopSpec.tea("Sencha")
      unplaced = TeaShopSpec.order({tea, 1})
      unplaced.cancel
      unplaced.cancelled?.should be_true

      order = TeaShopSpec.order({tea, 2})
      order.place
      TeaShopSpec.drain(connection)
      order.cancel
      expect_raises(SweetTalk::Refusal, "Order cannot become shipped while cancelled") do
        order.ship
      end

      TeaShopSpec.drain(connection)
      parcel = TeaShopSpec.parcel
      parcel.withdrawn?.should be_true
      expect_raises(SweetTalk::Refusal, "Parcel cannot become dispatched while withdrawn") do
        parcel.dispatch
      end
    end
  end

  it "notes a parcel that left before its order was cancelled" do
    SweetTalkSpec.rolled_back do |connection|
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      order.place
      TeaShopSpec.drain(connection)
      TeaShopSpec.parcel.dispatch
      order.cancel
      TeaShopSpec.drain(connection)

      found = Ordering::Order.find(order.id)
      found.cancelled?.should be_true
      found.late_parcel.should be_true
      shelf = Catalogue::Tea.find(tea.id)
      {shelf.stock.raw, shelf.held.raw}.should eq({3, 0})
      TeaShopSpec.holds.should eq([{"Sencha", "taken"}])
      TeaShopSpec.jobs.count(&.[:failed]).should eq(0)
      Ordering::Order.all(satisfying: Ordering::Astray).map(&.id).should eq([order.id])
      expect_raises(SweetTalk::Refusal, "An order whose parcel left cannot be forgotten.") do
        found.forget
      end
    end
  end

  it "lapses a hold after seven days, and cancels its order" do
    SweetTalkSpec.rolled_back do |connection|
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      order.place
      TeaShopSpec.drain(connection)
      lapses = SugarORM.sql("SELECT run_at FROM caramel_jobs WHERE class_name = $1",
        TeaShopSpec::LAPSE, as: {run_at: Time})
      lapses.size.should eq(1)
      (lapses.first[:run_at] - Time.utc - 7.days).abs.should be < 1.minute

      TeaShopSpec.drain(connection, true)
      Ordering::Order.find(order.id).cancelled?.should be_true
      reasons = TeaShopSpec.fields(TeaShopSpec::CANCELLED_BY_HOLD).map(&.["reason"]).uniq!
      reasons.should eq([JSON::Any.new("not dispatched within 7 days")])
      Catalogue::Tea.find(tea.id).held.raw.should eq(0)
      actors = TeaShopSpec.meta(TeaShopSpec::CANCELLED_BY_HOLD).map(&.["by"]).uniq!
      actors.should eq([JSON::Any.new("deadline Hold.lapse")])
    end
  end

  it "disarms the lapse when the parcel leaves" do
    SweetTalkSpec.rolled_back do |connection|
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      order.place
      TeaShopSpec.drain(connection)
      TeaShopSpec.parcel.dispatch
      TeaShopSpec.drain(connection)

      Ordering::Hold.all.first.lapse_due.should be_nil
      TeaShopSpec.drain(connection, true).should eq(1)
      Ordering::Order.find(order.id).shipped?.should be_true
      TeaShopSpec.jobs.count(&.[:failed]).should eq(0)
    end
  end

  it "serializes two commands on one aggregate with the row lock" do
    SweetTalkSpec.committed do
      tea = TeaShopSpec.tea("Sencha")
      done = Channel(Exception?).new
      spawn do
        SugarORM::Repo.transaction do
          Catalogue::Tea.find(tea.id).hold Catalogue::Tins.new(3)
          sleep 200.milliseconds
        end
        done.send(nil)
      rescue ex
        done.send(ex)
      end
      sleep 50.milliseconds
      second = Catalogue::Tea.find(tea.id)
      second.held.raw.should eq(0)
      expect_raises(SweetTalk::Refusal, "Only 2 tins of Sencha free.") do
        second.hold Catalogue::Tins.new(3)
      end
      done.receive.should be_nil
      Catalogue::Tea.find(tea.id).held.raw.should eq(3)
    end
  end

  it "keeps one projection row when two handlers insert its key at once" do
    SweetTalkSpec.committed do
      tea = TeaShopSpec.tea("Sencha")
      done = Channel(Exception?).new
      spawn do
        SweetTalk.__sweettalk_unit do
          Ordering::Sales[tea.id].sold += 1
          sleep 200.milliseconds
        end
        done.send(nil)
      rescue ex
        done.send(ex)
      end
      sleep 50.milliseconds
      SweetTalk.__sweettalk_unit { Ordering::Sales[tea.id].sold += 2 }
      done.receive.should be_nil
      Ordering::Sales.all.map { |row| {row.tea.raw, row.sold} }.should eq([{tea.id.raw, 3}])
    end
  end

  it "keeps both changes when two handlers update one projection row at once" do
    SweetTalkSpec.committed do
      tea = TeaShopSpec.tea("Sencha")
      SweetTalk.__sweettalk_unit { Ordering::Sales[tea.id].sold += 1 }
      done = Channel(Exception?).new
      spawn do
        SweetTalk.__sweettalk_unit do
          Ordering::Sales[tea.id].sold += 2
          sleep 200.milliseconds
        end
        done.send(nil)
      rescue ex
        done.send(ex)
      end
      sleep 50.milliseconds
      SweetTalk.__sweettalk_unit { Ordering::Sales[tea.id].sold += 4 }
      done.receive.should be_nil
      Ordering::Sales.all.map { |row| {row.tea.raw, row.sold} }.should eq([{tea.id.raw, 7}])
    end
  end

  it "notifies live pages with the subject's id on commit, and not on rollback" do
    SweetTalkSpec.committed do
      broker = Caramel::ColdBrew::Broker.new(SweetTalkSpec.url(SweetTalkSpec::RUNTIME_URL))
      Caramel::ColdBrew.broker = broker
      mailbox = Channel(String).new(4)
      begin
        Caramel::ColdBrew.subscribe("sweettalk.catalogue.tea.restocked", mailbox)
        tea = TeaShopSpec.tea("Sencha")
        tea.restock Catalogue::Tins.new(3)
        select
        when payload = mailbox.receive
          JSON.parse(payload).should eq(JSON.parse(%({"subject":#{tea.id}})))
        when timeout(1.second)
          fail "no notification within 1 s"
        end

        SugarORM::Repo.transaction do
          tea.restock Catalogue::Tins.new(1)
          SugarORM::Repo.rollback
        end
        select
        when payload = mailbox.receive
          fail "a rolled-back restock notified: #{payload}"
        when timeout(1.5.seconds)
        end
      ensure
        Caramel::ColdBrew.unsubscribe("sweettalk.catalogue.tea.restocked", mailbox)
        broker.close
        Caramel::ColdBrew.broker = nil
      end
    end
  end

  it "compiles the glossary and a context map with dependency and event edges" do
    glossary = SweetTalk.glossary.select { |term| TeaShopSpec::CONTEXTS.includes?(term.context) }
    tins = glossary.select { |term| term.name == "Tins" }.map { |term| {term.context, term.means} }
    tins.sort.should eq([
      {"Catalogue", "a count of tins on the shelf"},
      {"Fulfilment", "tins of one tea packed in a parcel"},
    ])
    glossary.size.should eq(28)
    terms = glossary.map { |term| {term.kind, term.name, term.context} }
    terms.should contain({"service", "requote", "Ordering"})
    terms.should contain({"process", "Hold", "Ordering"})
    SweetTalk.context_map.sort.should eq([
      {"Fulfilment", "Ordering", "event"},
      {"Ordering", "Catalogue", "dependency"},
      {"Ordering", "Fulfilment", "event"},
    ])
  end

  it "opens an order through its factory, and refuses a malformed email before writing" do
    SweetTalkSpec.rolled_back do
      member = TeaShopSpec.account
      expect_raises(SweetTalk::Refusal, "Email must match /\\A[^@\\s]+@[^@\\s]+\\z/") do
        Ordering::Order.open(member, Ordering::Email.new("ada"), TeaShopSpec.address)
      end
      SweetTalkSpec.count("ordering_orders").should eq(0)

      email = Ordering::Email.new("ada@example.com")
      order = Ordering::Order.open(member, email, TeaShopSpec.address)
      found = Ordering::Order.find(order.id)
      {found.open?, found.receipt_to.raw, found.late_parcel}.should eq({true, email.raw, false})
    end
  end

  it "stores an address one column per part, and rebuilds it on load" do
    SweetTalkSpec.rolled_back do
      order = TeaShopSpec.order
      columns = {deliver_to_street: String, deliver_to_city: String, deliver_to_postcode: String}
      stored = SugarORM.sql(TeaShopSpec::ADDRESSES, as: columns).map(&.values)
      stored.should eq([{"1 Leaf Lane", "Camellia", "CA1 1TE"}])
      Ordering::Order.find(order.id).deliver_to.should eq(TeaShopSpec.address)
      expect_raises(SweetTalk::Refusal, "An address needs a street and a city.") do
        TeaShopSpec.address(" ")
      end
    end
  end

  it "finds a member's placed orders in one query per table" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      ada, bob = TeaShopSpec.account("ada@example.com"), TeaShopSpec.account("bob@example.com")
      first = TeaShopSpec.order({tea, 1}, member: ada)
      first.place
      second = TeaShopSpec.order({tea, 2}, member: ada)
      second.place
      TeaShopSpec.order({tea, 1}, member: ada)
      TeaShopSpec.order({tea, 1}, member: bob).place

      before = SugarORM::Repo.statements_executed
      found = Ordering::Order.placed_for(ada)
      (SugarORM::Repo.statements_executed - before).should eq(2)
      found.map(&.id).should eq([first.id, second.id])
      found.map(&.lines.size).should eq([1, 1])
    end
  end

  it "finds a member's newest orders, counts the placed ones, and finds the orders " \
     "holding a tea" do
    SweetTalkSpec.rolled_back do
      sencha, assam = TeaShopSpec.tea("Sencha"), TeaShopSpec.tea("Assam")
      ada, bob = TeaShopSpec.account("ada@example.com"), TeaShopSpec.account("bob@example.com")
      first = TeaShopSpec.order({sencha, 1}, member: ada).tap(&.place)
      second = TeaShopSpec.order({assam, 1}, member: ada).tap(&.place)
      third = TeaShopSpec.order({sencha, 1}, member: ada)
      bobs = TeaShopSpec.order({sencha, 1}, member: bob).tap(&.place)

      Ordering::Order.newest_for(ada, 2).map(&.id).should eq([third.id, second.id])
      Ordering::Order.placed_count_for(ada).should eq(2)
      Ordering::Order.holding(assam.id).map(&.id).should eq([second.id])
      third.cancel
      third.forget
      Ordering::Order.holding(sencha.id).map(&.id).sort_by!(&.raw).should eq([first.id, bobs.id])
    end
  end

  it "reads the best-selling teas from Sales with finds and counts" do
    SweetTalkSpec.rolled_back do |connection|
      teas = %w[Sencha Assam Darjeeling Earl\ Grey Genmaicha].map do |name|
        TeaShopSpec.tea(name, stock: 100)
      end
      ids = teas.map(&.id.raw)
      TeaShopSpec.order({teas[0], 3}, {teas[1], 4}).place
      TeaShopSpec.order({teas[0], 2}, {teas[2], 1}).place
      TeaShopSpec.order({teas[4], 6}).place
      TeaShopSpec.order({teas[3], 5})
      TeaShopSpec.drain(connection)
      sold = ->(rows : Array(Ordering::Sales)) { rows.map { |row| {row.tea.raw, row.sold} } }

      sold.call(Ordering::Sales.best_sellers(2)).should eq([{ids[4], 6}, {ids[0], 5}])
      sold.call(Ordering::Sales.selling(4)).should eq([{ids[4], 6}, {ids[0], 5}, {ids[1], 4}])
      Ordering::Sales.of(teas[1]).map(&.sold).should eq([4])
      Ordering::Sales.of(teas[3]).should be_empty
      before = SugarORM::Repo.statements_executed
      Ordering::Sales.sold_any.should eq(4)
      (SugarORM::Repo.statements_executed - before).should eq(1)
      sold.call(Ordering::Sales.of_teas([ids[2], ids[0], ids[3]]))
        .should eq([{ids[0], 5}, {ids[2], 1}])
    end
  end

  it "forgets a cancelled order: find, find? and finds skip it, and its row stays" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 1})
      expect_raises(SweetTalk::Refusal, "Only a cancelled order can be forgotten.") do
        order.forget
      end
      order.cancel
      order.forget

      Ordering::Order.find?(order.id).should be_nil
      expect_raises(SweetTalk::Missing, "There is no Order #{order.id}.") do
        Ordering::Order.find(order.id)
      end
      Ordering::Order.all.should be_empty
      SweetTalkSpec.count("ordering_orders").should eq(1)
      removed = "SELECT removed_at IS NOT NULL AS removed FROM ordering_orders"
      SugarORM.sql(removed, as: {removed: Bool}).should eq([{removed: true}])
    end
  end

  it "requotes an order at today's prices and leaves it unchanged" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      tea.reprice Catalogue::Cents.new(1000)
      Ordering.requote(order.id).raw.should eq(2000)
      Ordering::Order.find(order.id).total.raw.should eq(1800)
    end
  end

  it "records who acted and when, and runs policies as that actor" do
    SweetTalkSpec.rolled_back do |connection|
      sencha, gyokuro = TeaShopSpec.tea("Sencha"), TeaShopSpec.tea("Gyokuro", 1)
      order = TeaShopSpec.order({sencha, 2}, {gyokuro, 2})
      SweetTalk.acting("member:7") { order.place }

      names = [TeaShopSpec::PLACED_BY_FULFILMENT, TeaShopSpec::PLACED_BY_SALES,
               TeaShopSpec::PLACED_BY_HOLD]
      placed = names.flat_map { |name| TeaShopSpec.meta(name) }
      placed.size.should eq(5)
      placed.map(&.["by"]).uniq!.should eq([JSON::Any.new("member:7")])
      placed.map(&.["id"]).uniq!.size.should eq(1)
      placed.each do |meta|
        (Time.parse_rfc3339(meta["at"].as_s) - Time.utc).abs.should be < 1.minute
      end

      TeaShopSpec.drain(connection)
      cancelled = TeaShopSpec.meta(TeaShopSpec::CANCELLED_BY_HOLD)
      cancelled.size.should eq(2)
      cancelled.map(&.["by"]).uniq!.should eq([JSON::Any.new("member:7")])
    end
  end

  it "links each event and job that follows a command by its cause and flow" do
    SweetTalkSpec.rolled_back do |connection|
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      flow = "4bf92f3577b34da6a3ce929d0e0e4736"
      trace = Caramel::Crema::Trace.new(Caramel::Crema::Kind::Request, "spec", flow,
        "00f067aa0ba902b7")
      Caramel::Crema.bound(trace) { order.place }
      TeaShopSpec.drain(connection)
      TeaShopSpec.drain(connection, true)

      names = [TeaShopSpec::PLACED_BY_FULFILMENT, TeaShopSpec::PLACED_BY_SALES,
               TeaShopSpec::PLACED_BY_HOLD]
      placed = names.flat_map { |name| TeaShopSpec.meta(name) }
      placed.size.should eq(3)
      placed.map(&.["flow"]).uniq!.should eq([JSON::Any.new(flow)])
      placed.map(&.["cause"]).uniq!.should eq([JSON::Any.new(nil)])
      ids = placed.map(&.["id"].as_s).uniq!
      ids.size.should eq(1)
      id = ids.first

      lapse = SugarORM.sql("SELECT payload->>'cause' AS cause, payload->>'flow' AS flow " \
                           "FROM caramel_jobs WHERE class_name = $1", TeaShopSpec::LAPSE,
        as: {cause: String?, flow: String?})
      lapse.should eq([{cause: id, flow: flow}])

      cancelled = [TeaShopSpec::CANCELLED_BY_HOLD, TeaShopSpec::CANCELLED_BY_FULFILMENT]
        .flat_map { |name| TeaShopSpec.meta(name) }
      cancelled.size.should eq(2)
      cancelled.map(&.["cause"]).uniq!.should eq([JSON::Any.new(id)])
      cancelled.map(&.["flow"]).uniq!.should eq([JSON::Any.new(flow)])
    end
  end

  it "starts one flow outside a trace and keeps it through every job" do
    SweetTalkSpec.rolled_back do |connection|
      tea = TeaShopSpec.tea("Sencha")
      order = TeaShopSpec.order({tea, 2})
      order.place
      TeaShopSpec.drain(connection)
      TeaShopSpec.drain(connection, true)

      names = [TeaShopSpec::PLACED_BY_FULFILMENT, TeaShopSpec::PLACED_BY_SALES,
               TeaShopSpec::PLACED_BY_HOLD, TeaShopSpec::CANCELLED_BY_HOLD,
               TeaShopSpec::CANCELLED_BY_FULFILMENT]
      metas = names.flat_map { |name| TeaShopSpec.meta(name) }
      metas.size.should eq(5)
      lapse = SugarORM.sql("SELECT payload->>'flow' AS flow FROM caramel_jobs " \
                           "WHERE class_name = $1", TeaShopSpec::LAPSE, as: {flow: String?})
      flows = (metas.map(&.["flow"].as_s) + lapse.map(&.[:flow])).uniq!
      flows.size.should eq(1)
      flows.first.should match(/\A[0-9a-f]{32}\z/)

      untraced = SugarORM.sql("SELECT count(*) AS count FROM caramel_jobs " \
                              "WHERE class_name = $1 AND context IS NULL",
        TeaShopSpec::PLACED_BY_SALES, as: {count: Int64})
      untraced.first[:count].should eq(1)
    end
  end

  it "loads an event and a deadline queued before causes and flows were recorded" do
    id = "6f1c2a9e-0000-4000-8000-000000000001"
    meta = {id: id, at: "2026-10-11T00:00:00.000000Z", by: nil}.to_json
    event = Ordering::Order::Cancelled.__sweettalk_load(1_i64, %({"lines":[],"reason":null}), meta)
    event.cause_id.should be_nil
    event.flow_id.should eq(id)

    deadline = TeaShop::Ordering::Hold::LapseDeadline.from_json(%({"key":"{}","arming":1}))
    deadline.cause.should be_nil
    deadline.flow.should be_nil
  end

  it "carries a nilable fact" do
    SweetTalkSpec.rolled_back do
      tea = TeaShopSpec.tea("Sencha")
      TeaShopSpec.order({tea, 1}).cancel
      TeaShopSpec.order({tea, 1}).cancel "changed my mind"

      payload = {subject: String, fields: String, meta: String}
      rows = SugarORM.sql(TeaShopSpec::PAYLOADS, TeaShopSpec::CANCELLED_BY_FULFILMENT, as: payload)
      reasons = rows.map { |row| JSON.parse(row[:fields])["reason"] }
      reasons.should eq([JSON::Any.new(nil), JSON::Any.new("changed my mind")])
      events = rows.map do |row|
        Ordering::Order::Cancelled.__sweettalk_load(row[:subject].to_i64, row[:fields], row[:meta])
      end
      events.map(&.reason).should eq([nil, "changed my mind"])
    end
  end

  it "refers to the application's account by id" do
    SweetTalkSpec.rolled_back do
      member = TeaShopSpec.account
      order = TeaShopSpec.order(member: member)
      found = Ordering::Order.find(order.id)
      found.member.should eq(SweetTalk::RecordId(TeaShop::Account).new(member.id))
      found.member.load.email.should eq("ada@example.com")
    end
  end

  it "runs the whole flow on two Cold Brew worker pools" do
    SweetTalkSpec.committed do
      workers = Array.new(2) { Caramel::ColdBrew::Worker.new("default", 2, SweetTalkSpec.runtime) }
      begin
        workers.each(&.start)
        tea = TeaShopSpec.tea("Sencha")
        order = TeaShopSpec.order({tea, 2})
        order.place
        SweetTalkSpec.eventually("a packed parcel with 2 tins held") do
          packed = Fulfilment::Parcel.all.first?.try(&.packed?)
          packed && Catalogue::Tea.find(tea.id).held.raw == 2
        end

        TeaShopSpec.parcel.dispatch
        SweetTalkSpec.eventually("a shipped order with 3 tins left") do
          Ordering::Order.find(order.id).shipped? && Catalogue::Tea.find(tea.id).stock.raw == 3
        end
      ensure
        workers.each(&.stop)
      end
    end
  end
end
