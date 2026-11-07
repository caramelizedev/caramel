require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Seating, means: "selling the seats of each show" do
    aggregate Show, means: "one performance and the seats it sells" do
      has title : String
      moves on_sale >> closed, on_sale >> postponed >> on_sale

      to close do
        closed!
      end
    end
  end
end

# The buttons a show's page offers, written before a show could be postponed.
def offers(show : Shop::Seating::Show) : Array(String)
  Shop::Seating::Show.moves_from(show.state).map do |state|
    case state
    in .on_sale? then "Put on sale"
    in .closed?  then "Close sales"
    end
  end
end

offers(Shop::Seating::Show.find(Shop::Seating::Show::Id.new(1_i64)))
SweetTalk.boot
