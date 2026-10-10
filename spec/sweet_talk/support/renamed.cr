# A domain after a rename: every kind that stores a name takes `renamed_from:`, so the
# tables, the channel and queued jobs of the old names keep working.
require "../../../src/caramel/sweet_talk"

module Renamed
  include SweetTalk

  context Pantry, renamed_from: Store, means: "the shop's stock" do
    value Tins, Int32, at_least: 0, means: "a count of tins"

    aggregate Blend, renamed_from: Tea, means: "one tea we sell" do
      has name : String
      has stock : Tins
      has cans : Array(Can)

      entity Can, renamed_from: Tin, means: "one labelled tin of the tea" do
        has label : String
      end

      event Refilled, tins : Tins, renamed_from: Restocked,
        means: "fresh tins reached the shelf"

      to refill(tins : Tins) do
        @stock += tins
        emit Refilled, tins: tins
      end
    end

    projection Larder, renamed_from: Stockroom, means: "tins restocked of one tea" do
      key tea : Blend
      has restocked : Int32 = 0

      whenever Blend::Refilled do |refilled|
        Larder[refilled.blend_id].restocked += refilled.tins.raw
      end
    end
  end
end
