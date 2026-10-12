require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Kitchen, means: "where the tea is brewed" do
    value Grams, Float64, means: "grams of leaves"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
