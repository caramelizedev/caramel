require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/tenancy"

module Fixture
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
      index :slug, unique: true
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

module Shop
  include SweetTalk

  struct Org < SugarORM::Schema
    schema "orgs" do
      field id : Int64, primary: true
      field slug : String
    end
  end

  tenant Org

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea" do
      has name : String
    end
  end
end

SweetTalk.boot
