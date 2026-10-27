require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/tenancy"

module Shop
  include SweetTalk

  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
      index :slug, unique: true
    end
  end

  tenant Account

  context Warehousing, means: "storing goods" do
    aggregate RefrigeratedShippingContainer, means: "a cold box" do
      has reading : Int32
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
