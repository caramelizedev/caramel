require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  SHORT = 1..8

  context Store, means: "the shelves" do
    value Code, String, length: SHORT, means: "a short code"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
