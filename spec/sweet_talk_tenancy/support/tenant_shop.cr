# A tea shop shared by tenants (ADR 0033): a central catalogue every tenant sells from,
# tenanted ordering and fulfilment with a projection, a process and a deadline, and a
# central report that totals every tenant's orders.
module TenantShop
  include SweetTalk

  # The slug of the tenant each Fulfilment policy ran in, in the order they ran.
  SEEN = [] of String

  # The application's tenants, a plain SugarORM schema the routes' tenant block names.
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
      index :slug, unique: true
    end
  end

  tenant Account

  context Catalogue, central: true, means: "the teas every tenant sells" do
    aggregate Tea, means: "one tea on every tenant's shelf" do
      has name : String
    end
  end

  context Ordering, follows: Catalogue, means: "choosing teas and checking out" do
    value Slot, means: "one tea in one order" do
      part order : Int64
      part tea : Int64
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has buyer : String
      has lines : Array(Line)
      moves open >> placed >> cancelled, open >> cancelled

      entity Line, means: "tins of one tea in an order" do
        has tea : Catalogue::Tea
        has tins : Int32
      end

      event Placed, lines : Array(Line), means: "a member checked out"
      event Cancelled, means: "the order was given up"

      factory open(buyer : String) do
      end

      to add(tea : Catalogue::Tea, tins : Int32) do
        @lines << Line.new(tea, tins)
      end

      to place do
        placed!
        emit Placed, lines: lines
      end

      to cancel do
        unless cancelled?
          cancelled!
          emit Cancelled
        end
      end
    end

    projection Sales, means: "tins sold of one tea" do
      key tea : Catalogue::Tea
      has sold : Int32 = 0

      whenever Order::Placed, each: :lines do |placed, line|
        Sales[line.tea].sold += line.tins
      end
    end

    process Hold, means: "tins of one tea held for one placed order" do
      key slot : Slot
      has tins : Int32 = 0
      moves waiting >> holding >> released

      whenever Order::Placed, each: :lines,
        key: Slot.new(order: placed.order_id.raw, tea: line.tea.raw) do |placed, line|
        if waiting?
          @tins = line.tins
          holding!
          arm lapse
        end
      end

      deadline lapse, after: 7.days do
        if holding?
          Order.find(Order::Id.new(slot.order)).cancel
          released!
        end
      end
    end
  end

  context Fulfilment, means: "packing parcels" do
    aggregate Parcel, means: "the box we pack for one order" do
      has order : Int64

      factory pack(order : Int64) do
      end
    end

    border Ordering do
      whenever Ordering::Order::Placed do |placed|
        TenantShop::SEEN << Caramel::Tenancy.current.slug
        Parcel.pack placed.order_id.raw
      end
    end
  end

  context Reporting, follows: Ordering, central: true, means: "figures every tenant shares" do
    projection Totals, means: "tins ordered of one tea, across every tenant" do
      key tea : Int64
      has tins : Int32 = 0

      whenever Ordering::Order::Placed, each: :lines do |placed, line|
        Totals[line.tea.raw].tins += line.tins
      end
    end
  end
end
