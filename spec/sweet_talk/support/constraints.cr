# A pantry for SweetTalk's database constraints (ADR 0045): a crate whose label and code
# are unique, with a plain index and a check on one attribute; an adjustment unique by two
# attributes together, indexed by two, with a check over its lifecycle; and a shipment
# whose parcels are unique by tag within it.
require "../../../src/caramel/sweet_talk"

module Constrained
  include SweetTalk

  context Pantry, means: "a pantry whose rules PostgreSQL keeps too" do
    aggregate Crate, means: "a crate with a label and a code of its own" do
      has label : String, unique: true
      has code : String, unique: "A crate with this code already exists."
      has owner : String, index: true
      has quantity : Int32, check: {"quantity >= 0", "A crate cannot hold less than nothing."}

      to take(count : Int32) do
        @quantity -= count
      end

      to relabel(label : String) do
        @label = label
      end
    end

    aggregate Adjustment, means: "one correction to one bundle of a source" do
      has source_key : String
      has bundle : String
      has debit : Int32 = 0
      has credit : Int32 = 0
      moves pending >> posted

      unique :source_key, :bundle, otherwise: "That bundle already has an adjustment."
      index :bundle, :state
      check :pending_is_zero, "state <> 'pending' OR (debit = 0 AND credit = 0)",
        otherwise: "A pending line carries no amounts."

      to post do
        posted!
      end

      to debit(amount : Int32) do
        @debit += amount
      end
    end

    aggregate Shipment, means: "parcels sent together, each tagged once" do
      has parcels : Array(Parcel)

      entity Parcel, means: "one parcel in a shipment" do
        has tag : String
        unique :tag

        def retag(tag : String) : Nil
          @tag = tag
        end
      end

      to pack(tag : String) do
        @parcels << Parcel.new(tag: tag)
      end

      to repack(tag : String) do
        @parcels = [Parcel.new(tag: tag)]
      end

      to swap_tags do
        first, second = parcels[0], parcels[1]
        tag = first.tag
        first.retag second.tag
        second.retag tag
      end
    end
  end
end
