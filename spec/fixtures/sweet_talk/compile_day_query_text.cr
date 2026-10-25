require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    value Day, Date, means: "a calendar day"

    aggregate Parcel, means: "a parcel that leaves on a day" do
      has shipped_on : Day?

      finds shipped_between(from : String, to : String), where: {shipped_on: from..to}
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
