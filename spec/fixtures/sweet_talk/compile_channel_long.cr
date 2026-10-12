require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Warehousing, means: "storing goods" do
    aggregate RefrigeratedShippingContainer, means: "a cold box" do
      has reading : Int32

      event TemperatureReadingRecorded, means: "the box reported its temperature"
    end
  end
end

SweetTalk.boot
