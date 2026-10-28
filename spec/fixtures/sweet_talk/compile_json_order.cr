require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pricing, means: "what each tea costs" do
    value Evidence, Json, means: "the figures a price was set from"

    aggregate Price, means: "what one tea costs" do
      has evidence : Evidence

      finds by_evidence, order: {evidence: :asc}
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
