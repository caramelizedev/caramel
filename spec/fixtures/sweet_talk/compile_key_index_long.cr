require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Warehousing, means: "storing goods" do
    projection ContainerReadings, means: "the last reading of each container" do
      key refrigerated_container_serial_number : Int64
      has reading : Int32 = 0
    end
  end
end

SweetTalk.boot
