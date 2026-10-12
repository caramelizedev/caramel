# The tea shop's domain: values, aggregates, factories, queries, removal, a domain service,
# projections, a process with a deadline and a compensation, a reference to the
# application's own schema, and events that record who acted and when.
require "../../../src/caramel/sweet_talk"

module TeaShop
  include SweetTalk

  # The application's member accounts, a plain SugarORM schema.
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field email : String
    end
  end

  context Catalogue, means: "the teas on our shelves" do
    value Tins, Int32, at_least: 0, means: "a count of tins on the shelf"
    value Cents, Int64, at_least: 0, means: "an amount of money"

    aggregate Tea, means: "one tea we sell" do
      has name : String
      has price : Cents
      has stock : Tins
      has held : Tins = Tins.zero
      never "A tea cannot hold more tins than it has." { held > stock }

      event Restocked, tins : Tins, means: "fresh tins reached the shelf"

      to restock(tins : Tins) do
        @stock += tins
        emit Restocked, tins: tins
      end

      to reprice(price : Cents) do
        @price = price
      end

      to hold(tins : Tins) do
        refuse "Only #{stock - held} tins of #{name} free." if held + tins > stock
        @held += tins
      end

      to release(tins : Tins) do
        @held -= tins
      end

      to ship_held(tins : Tins) do
        @held -= tins
        @stock -= tins
      end

      to ship_free(tins : Tins) do
        refuse "Only #{stock - held} tins of #{name} free." if held + tins > stock
        @stock -= tins
      end
    end
  end

  context Ordering, follows: Catalogue, means: "choosing teas and checking out" do
    value Quantity, Int32, within: 1..10, means: "tins of one tea in one order"
    value Email, String, matches: /\A[^@\s]+@[^@\s]+\z/, length: 3..254,
      means: "an address we can write to"
    value Postcode, String, matches: /\A[A-Z0-9][A-Z0-9 ]{1,8}[A-Z0-9]\z/,
      means: "a postal code, in capitals"

    value Address, means: "where a parcel goes" do
      part street : String
      part city : String
      part postcode : Postcode
      never "An address needs a street and a city." { street.blank? || city.blank? }
    end

    value Slot, means: "one tea in one order" do
      part order : Int64
      part tea : Int64
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has member : Account
      has receipt_to : Email
      has deliver_to : Address
      has lines : Array(Line)
      has late_parcel : Bool = false
      moves open >> placed >> shipped, open >> cancelled, placed >> cancelled
      never "An order needs at least one tea." { placed? && lines.empty? }

      entity Line, means: "one tea in an order, its price when added, and how many tins" do
        has tea : Catalogue::Tea
        has price : Catalogue::Cents
        has quantity : Quantity
        the cost : Catalogue::Cents = price * quantity.to_i
      end

      the total : Catalogue::Cents = lines.sum(&.cost)

      event Opened, receipt_to : Email, means: "a member started an order"
      event Placed, lines : Array(Line), deliver_to : Address, means: "a member checked out"
      event Shipped, means: "the order left in its parcel"
      event Cancelled, lines : Array(Line), reason : String?,
        means: "the order was given up, and why"

      factory open(member : Account, receipt_to : Email, deliver_to : Address) do
        emit Opened, receipt_to: receipt_to
      end

      finds placed_for(member : Account), where: {member: member, state: :placed}

      to add(tea : Catalogue::Tea, quantity : Quantity) do
        refuse "Teas can be added only while the order is open." unless open?
        refuse "#{tea.name} is already in this order." if lines.any? { |line| line.tea == tea.id }
        @lines << Line.new(tea, tea.price, quantity)
      end

      to place do
        placed!
        emit Placed, lines: lines, deliver_to: deliver_to
      end

      to ship do
        shipped!
        emit Shipped
      end

      to cancel(reason : String? = nil) do
        unless cancelled?
          cancelled!
          emit Cancelled, lines: lines, reason: reason
        end
      end

      to note_late_parcel do
        refuse "Only a cancelled order can note a late parcel." unless cancelled?
        @late_parcel = true
      end

      to forget do
        refuse "Only a cancelled order can be forgotten." unless cancelled?
        remove
      end
    end

    service requote(order : Order::Id), returns: Catalogue::Cents,
      means: "what an order would cost at today's prices" do
      Order.find(order).lines.sum do |line|
        Catalogue::Tea.find(line.tea).price * line.quantity.to_i
      end
    end

    projection Sales, means: "tins sold of one tea" do
      key tea : Catalogue::Tea
      has sold : Int32 = 0

      whenever Order::Placed, each: :lines do |placed, line|
        Sales[line.tea].sold += line.quantity.to_i
      end
    end

    process Hold, means: "tins of one tea held on the shelf for one placed order" do
      key slot : Slot
      has tins : Int32 = 0
      moves waiting >> holding >> taken, waiting >> refused, waiting >> released,
        holding >> released

      whenever Order::Placed, each: :lines,
        key: Slot.new(order: placed.order_id.raw, tea: line.tea.raw) do |placed, line|
        if waiting?
          Catalogue::Tea.find(line.tea).hold Catalogue::Tins.new(line.quantity.to_i)
          @tins = line.quantity.to_i
          holding!
          arm lapse
        end
      end

      compensate Order::Placed do |placed, line, refusal|
        refused!
        Order.find(placed.order_id).cancel refusal.message
      end

      whenever Order::Cancelled, each: :lines,
        key: Slot.new(order: cancelled.order_id.raw, tea: line.tea.raw) do |cancelled, line|
        if holding?
          Catalogue::Tea.find(line.tea).release Catalogue::Tins.new(tins)
          disarm lapse
        end
        released! if waiting? || holding?
      end

      whenever Fulfilment::Parcel::Dispatched, each: :packings,
        key: Slot.new(order: dispatched.order, tea: packing.tea) do |dispatched, packing|
        tea = Catalogue::Tea.find(Catalogue::Tea::Id.new(packing.tea))
        if holding?
          tea.ship_held Catalogue::Tins.new(tins)
          taken!
          disarm lapse
        else
          tea.ship_free Catalogue::Tins.new(packing.tins.to_i)
        end
      end

      deadline lapse, after: 7.days do
        Order.find(Order::Id.new(slot.order)).cancel "not dispatched within 7 days" if holding?
      end
    end

    border Fulfilment do
      whenever Fulfilment::Parcel::Dispatched do |dispatched|
        Order.find(Order::Id.new(dispatched.order)).ship
      end

      compensate Fulfilment::Parcel::Dispatched do |dispatched, refusal|
        Order.find(Order::Id.new(dispatched.order)).note_late_parcel
      end
    end
  end

  context Fulfilment, means: "packing and dispatching parcels" do
    value Tins, Int32, at_least: 1, means: "tins of one tea packed in a parcel"

    value Label, means: "the address printed on a parcel" do
      part street : String
      part city : String
      part postcode : String
    end

    aggregate Parcel, means: "the box we dispatch for one order" do
      has order : Int64
      has packings : Array(Packing)
      has label : Label
      moves packed >> dispatched, packed >> withdrawn

      entity Packing, means: "the tins of one tea in a parcel" do
        has tea : Int64
        has tins : Tins
      end

      event Packed, order : Int64, means: "a parcel was packed for an order"
      event Dispatched, order : Int64, packings : Array(Packing), means: "a parcel left the shop"

      factory pack(order : Int64, packings : Array(Packing), label : Label) do
        emit Packed, order: order
      end

      finds for_order(order : Int64), where: {order: order}

      to dispatch do
        dispatched!
        emit Dispatched, order: order, packings: packings
      end

      to withdraw do
        withdrawn! if packed?
      end
    end

    border Ordering do
      whenever Ordering::Order::Placed do |placed|
        packings = placed.lines.map do |line|
          Parcel::Packing.new(line.tea.raw, Tins.new(line.quantity))
        end
        address = placed.deliver_to
        label = Label.new(street: address.street, city: address.city,
          postcode: address.postcode.raw)
        Parcel.pack placed.order_id.raw, packings, label
      end

      whenever Ordering::Order::Cancelled do |cancelled|
        Parcel.for_order(cancelled.order_id.raw).first?.try(&.withdraw)
      end
    end
  end
end
