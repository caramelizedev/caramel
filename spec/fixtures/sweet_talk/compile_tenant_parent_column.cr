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

  context Billing, means: "charging for what we sell" do
    aggregate Account, means: "what one customer owes" do
      has lines : Array(Charge)

      entity Charge, means: "one amount charged" do
        has cents : Int64
      end
    end
  end

  struct Home < Caramel::Action
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
