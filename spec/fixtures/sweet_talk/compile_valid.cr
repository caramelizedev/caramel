require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  MOST_PARCELS = 5

  context Ordering, subdomain: :core, means: "choosing teas and checking out" do
    value Quantity, Int32, within: 1..10, means: "tins of one tea in one order"
    value Email, String, matches: /\A[^@\s]+@[^@\s]+\z/, length: 3..254,
      means: "an address we can write to"
    value Parcels, Int32, at_least: 1, at_most: MOST_PARCELS, database_check: false,
      means: "how many parcels an order ships in"

    value Roast, String, one_of: %w[light medium dark], means: "how far a tea is roasted"
    value Courier, String, length: 2..30, means: "who carries an order"
    value Day, Date, means: "a calendar day"

    value Address, means: "where a parcel goes" do
      part street : String
      part city : String
      never "An address needs a street and a city." { street.blank? || city.blank? }
    end

    value Term, means: "the days a tea is held" do
      part from_on : Day
      part until_on : Day
    end

    aggregate Tea, means: "one tea we sell" do
      has name : String
    end

    # An aggregate with a lifecycle and no attributes still builds.
    aggregate Bell, means: "the bell by the door" do
      moves silent >> rung
      event Rung, means: "someone rang"

      to ring do
        rung!
        emit Rung
      end
    end

    # An aggregate may refer to its own type.
    aggregate Entry, means: "one line of the journal" do
      has amount : Int64
      has reversal_of : Entry?

      to reverse(entry : Entry) do
        self.reversal_of = entry
      end
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has receipt_to : Email
      has deliver_to : Address
      has lines : Array(Line)
      has parcels : Parcels = Parcels.new(1)
      has gift_to : Address?
      has shipped_by : Courier?
      has roast : Roast?
      has packer : Int64?
      has tea : Tea?
      has shipped_on : Day?
      has parcels_count : Int32 = 1
      has term : Term?
      # A carried name kept while `shipped_by` becomes `courier` (ADR 0041).
      the courier : Courier? = shipped_by
      moves open >> placed, open >> cancelled, placed >> cancelled

      # A defaulted attribute may sit between required ones: `Line.new` by name leaves it
      # out, and an entity has its own invariants.
      entity Line, means: "one tea in an order and how many tins" do
        has tea : Int64
        has note : String = ""
        has quantity : Quantity
        never "A line names a tea." { tea <= 0 }
      end

      event Opened, receipt_to : Email, means: "a member started an order"
      event Placed, lines : Array(Line), means: "a member checked out"
      event Cancelled, reason : String?, means: "the order was given up, and why"
      event Shipped, carries: [receipt_to, gift_to, shipped_by, roast, courier, tea, shipped_on],
        means: "an order left, with what it said when it left"

      factory open(receipt_to : Email, deliver_to : Address) do
        emit Opened, receipt_to: receipt_to
      end

      finds placed_to(receipt_to : Email), where: {receipt_to: receipt_to, state: :placed}
      finds newest(count : Int32), order: {id: :desc}, first: count
      counts placed_count, where: {state: :placed}
      finds shipped_between(from : Day, to : Day), where: {shipped_on: from..to},
        order: {shipped_on: :desc}
      counts shipped_since(day : Day), where: {shipped_on: day..}
      sums teas_placed, of: Line.tea, where: {state: :placed}
      groups teas_by_note(from : Day), of: Line.tea, by: Line.note,
        where: {shipped_on: from.., state: :placed}
      groups lines_by_tea, of: Line.tea, by: Line.tea
      groups by_state, of: :parcels_count, by: :state
      groups by_day, of: :parcels_count, by: :shipped_on
      groups by_tea, of: :parcels_count, by: :tea
      groups by_roast, of: :parcels_count, by: :roast, where: {state: :placed}
      finds holding(tea : Int64) do |orders|
        orders.where("id IN (SELECT order_id FROM ordering_order_lines WHERE tea = ?)", tea)
      end

      to add(tea : Int64, quantity : Quantity) do
        refuse "Teas can be added only while the order is open." unless open?
        @lines << Line.new(tea: tea, quantity: quantity)
      end

      to place do
        placed!
        emit Placed, lines: lines
      end

      to ship(by : Courier, on : Day) do
        @shipped_by = by
        @shipped_on = on
        emit Shipped
      end

      to unwrap_gift do
        @gift_to = nil
      end

      # Neither a comparison, a hash rocket, an argument before a comparison nor a string is
      # a stray write of the reference.
      to choose(tea : Tea) do
        refuse "@tea = tea is how a stray write looks" if @tea_id == tea.id.raw
        seen = {@tea_id => lines.size}
        refuse "Too many teas." if seen.fetch(@tea_id, lines.size >= 9 ? 1 : 0) > 0
        self.tea = tea
      end

      to cancel(reason : String? = nil) do
        unless cancelled?
          cancelled!
          emit Cancelled, reason: reason
        end
      end
    end

    specification Settled, on: Order, where: {state: [:placed, :cancelled]},
      means: "an order no longer being filled"
    specification ShippedInSpring, on: Order,
      where: {shipped_on: Day.new(2026, 3, 1)..Day.new(2026, 5, 31)},
      means: "an order that left between 1 March and 31 May 2026"

    projection Sales, means: "tins sold of one tea" do
      key tea : Int64
      has sold : Int32 = 0

      finds best_sellers(count : Int32), order: {sold: :desc}, first: count
      counts selling, where: {sold: 1..}
      sums tins_sold, of: :sold
      groups sold_by_tea, of: :sold, by: :tea

      whenever Order::Placed, each: :lines do |placed, line|
        Sales[line.tea].sold += line.quantity.raw
      end
    end

    whenever Order::Opened do |opened|
      opened.receipt_to
    end

    service lines(order : Order::Id), returns: Int32, means: "how many lines an order has" do
      Order.find(order).lines.size
    end

    publishes Quantity, Order::Id, lines

    border Mail, outside: "the mail service we send receipts through" do
      def self.send_receipt(to : String) : Int32
        url = "https://mail.example/v1/messages"
        Caramel::Outbound.post(url, HTTP::Headers.new, to).status_code
      end
    end

    process Hold, means: "tins held on the shelf for one placed order" do
      key order : Int64
      has tins : Int32 = 0
      moves waiting >> holding, waiting >> refused, holding >> released

      whenever Order::Placed, key: placed.order_id.raw do |placed|
        if waiting?
          @tins = placed.lines.sum(&.quantity.to_i)
          holding!
          arm lapse
        end
      end

      compensate Order::Placed do |placed, refusal|
        refused!
        Order.find(placed.order_id).cancel refusal.message
      end

      deadline lapse, after: 7.days do
        if holding?
          released!
          Order.find(Order::Id.new(order)).cancel "not dispatched within 7 days"
        end
      end
    end
  end
end

# An action whose contract binds an aggregate's id, a value and a list of values.
struct AddLine < Caramel::Action
  contract do
    field order : Shop::Ordering::Order::Id
    field quantity : Shop::Ordering::Quantity
    field tags : Array(Shop::Ordering::Quantity), max: 3
    field shipped_on : Shop::Ordering::Day?
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "#{contract.order} #{contract.quantity.raw} #{contract.tags.size}")
  end
end

module Shop
  Caramel::Router.draw do
    post "/orders/:order/lines", AddLine
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
Shop::Ordering::Order.all(satisfying: Shop::Ordering::Settled)
Shop::Ordering::Order.all.each do |order|
  order.ship(Shop::Ordering::Courier.new("post"), Shop::Ordering::Day.new(2026, 3, 1))
  order.shipped_on.try { |day| day + 7 - 7 }
  Shop::Ordering::Order.shipped_between(Shop::Ordering::Day.of(Time.utc),
    Shop::Ordering::Day.new("2026-12-31"))
  order.unwrap_gift
end
Shop::Ordering::Bell.create.ring
