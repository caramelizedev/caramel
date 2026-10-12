require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pantry, means: "the shop's stock" do
    aggregate Blend, means: "one tea we sell" do
      has stock : Int32

      event Refilled, tins : Int32, renamed_from: Restocked, means: "fresh tins reached the shelf"
      event Restocked, tins : Int32, means: "the supplier refilled its own stock"
    end

    projection Larder, means: "tins of one tea" do
      key tea : Blend
      has refilled : Int32 = 0
      has restocked : Int32 = 0

      whenever Blend::Refilled do |refilled|
        Larder[refilled.blend_id].refilled += refilled.tins
      end

      whenever Blend::Restocked do |restocked|
        Larder[restocked.blend_id].restocked += restocked.tins
      end
    end
  end
end

Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
