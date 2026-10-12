require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Warehousing, means: "storing goods" do
    value Celsius, Int32, within: -40..40, means: "a temperature"

    aggregate RefrigeratedShippingContainer, means: "a cold box" do
      has maximum_temperature_reading : Celsius
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
