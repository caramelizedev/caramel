require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Ordering, means: "choosing teas and checking out" do
    value Email, String, at_least: 3, means: "an address we can write to"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
