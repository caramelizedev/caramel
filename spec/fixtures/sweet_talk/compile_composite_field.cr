require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    value Address, means: "where a parcel goes" do
      part street : String
      part city : String
    end
  end

  struct Deliver < Caramel::Action
    contract do
      field to : Ordering::Address
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end
  end

  Caramel::Router.draw do
    post "/deliveries", Deliver
  end
end
