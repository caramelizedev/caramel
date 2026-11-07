require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/tenancy"

module Shop
  include SweetTalk
  ids Int64

  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : UUID, primary: true
      field slug : String
      index :slug, unique: true
    end
  end

  tenant Account

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea" do
      has name : String
    end
  end

  struct Home < Caramel::Action
    ingress open: true

    contract do
    end

    def handle(contract : Contract)
      page "Home", "<p>Home</p>"
    end
  end

  Caramel::Router.draw do
    tenant Account, by: :slug do
      get "/", Home
    end
  end
end

SweetTalk.boot
