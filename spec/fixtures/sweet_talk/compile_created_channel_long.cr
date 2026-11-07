require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Warehousing, means: "storing goods" do
    aggregate RefrigeratedShippingContainerForTransport, means: "a cold box" do
      has reading : Int32
    end
  end
end

SweetTalk.boot
