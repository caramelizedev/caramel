require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/corretto/property"

module Shop
  include SweetTalk
  ids Int64

  context Billing, means: "what members pay" do
    value Cents, Int64, at_least: 0, means: "an amount in cents"
    value Note, Json, means: "what a member wrote"

    calculation share(total : Cents, parts : Int32), returns: Cents,
      means: "one part of a total" do
      total
    end

    calculation annotate(note : Note), returns: Note, means: "a note as it is kept" do
      note
    end
  end
end

SweetTalk.boot
Corretto.property(Shop::Billing.annotate)
