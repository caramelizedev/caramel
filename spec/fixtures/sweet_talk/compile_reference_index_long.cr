require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Warehousing, means: "storing goods" do
    aggregate Warehouse, means: "a building we store goods in" do
      has name : String
    end

    aggregate RefrigeratedShippingContainer, means: "a cold box" do
      has destination_warehouse : Warehouse
    end
  end
end

SweetTalk.boot
