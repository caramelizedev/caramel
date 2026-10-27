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

module Shop
  include SweetTalk

  tenant Fixture::Account

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String

      counts named(name : String), where: {name: name}
    end

    projection Shelf, means: "teas shelved under one name" do
      key name : String
      has teas : Int32 = 0

      counts stocked, where: {teas: 1..}
    end
  end
end

SweetTalk.boot
