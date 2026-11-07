require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Warehousing, means: "storing goods" do
    aggregate Crate, means: "a crate on the shelf" do
      has reading : Int32

      event Created, label : String, means: "a crate was made"
    end
  end
end

SweetTalk.boot
