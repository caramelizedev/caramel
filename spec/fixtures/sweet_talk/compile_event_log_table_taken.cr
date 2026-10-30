require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, event_log: true, means: "choosing teas and checking out" do
    aggregate Event, means: "a tasting the shop holds" do
      has name : String
    end
  end
end

SweetTalk.boot
