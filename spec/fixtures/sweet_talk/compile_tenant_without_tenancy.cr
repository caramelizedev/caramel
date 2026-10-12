require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
    end
  end

  tenant Account

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea" do
      has name : String
    end
  end
end

SweetTalk.boot
