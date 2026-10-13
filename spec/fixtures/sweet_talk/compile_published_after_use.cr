require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Reporting, means: "counts for the owners" do
    border Catalogue do
      def self.tea_name(tea : Int64) : String
        Catalogue::Tea.find(Catalogue::Tea::Id.new(tea)).name
      end
    end
  end

  context Catalogue, means: "the teas on our shelves" do
    value Cents, Int64, at_least: 0, means: "an amount of money"

    aggregate Tea, means: "one tea we sell" do
      has name : String
      has price : Cents
      event Repriced, price : Cents, means: "a tea's price changed"
    end

    service price_of(tea : Tea::Id), returns: Cents, means: "what one tea costs today" do
      Tea.find(tea).price
    end

    service teas_on_shelf, returns: Int32, means: "how many teas we sell" do
      Tea.all.size
    end

    publishes Cents, Tea::Id, price_of
  end
end

SweetTalk.boot
