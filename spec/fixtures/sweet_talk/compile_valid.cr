require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  MOST_PARCELS = 5

  context Ordering, means: "choosing teas and checking out" do
    value Quantity, Int32, within: 1..10, means: "tins of one tea in one order"
    value Email, String, matches: /\A[^@\s]+@[^@\s]+\z/, length: 3..254,
      means: "an address we can write to"
    value Parcels, Int32, at_least: 1, at_most: MOST_PARCELS, database_check: false,
      means: "how many parcels an order ships in"

    value Address, means: "where a parcel goes" do
      part street : String
      part city : String
      never "An address needs a street and a city." { street.blank? || city.blank? }
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has receipt_to : Email
      has deliver_to : Address
      has lines : Array(Line)
      has parcels : Parcels = Parcels.new(1)
      moves open >> placed, open >> cancelled, placed >> cancelled

      entity Line, means: "one tea in an order and how many tins" do
        has tea : Int64
        has quantity : Quantity
      end

      event Opened, receipt_to : Email, means: "a member started an order"
      event Placed, lines : Array(Line), means: "a member checked out"
      event Cancelled, reason : String?, means: "the order was given up, and why"

      factory open(receipt_to : Email, deliver_to : Address) do
        emit Opened, receipt_to: receipt_to
      end

      finds placed_to(receipt_to : Email), where: {receipt_to: receipt_to, state: :placed}

      to add(tea : Int64, quantity : Quantity) do
        refuse "Teas can be added only while the order is open." unless open?
        @lines << Line.new(tea, quantity)
      end

      to place do
        placed!
        emit Placed, lines: lines
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

    whenever Order::Opened do |opened|
      opened.receipt_to
    end

    service lines(order : Order::Id), returns: Int32, means: "how many lines an order has" do
      Order.find(order).lines.size
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
