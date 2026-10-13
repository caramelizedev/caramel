require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Warehousing, means: "where we keep stock" do
    aggregate RefrigeratedShippingContainer, means: "a cold box we ship in" do
      has serial : String
      moves loading >> sealed >> shipped
    end
  end
end
