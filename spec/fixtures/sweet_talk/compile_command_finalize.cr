require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Run, means: "one run through a lifecycle" do
      has label : String
      moves open >> finalized

      to finalize(label : String) do
        @label = label
        finalized!
      end
    end
  end
end

SweetTalk.boot
Shop::Ordering::Run.create(label: "first").finalize("last")
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
