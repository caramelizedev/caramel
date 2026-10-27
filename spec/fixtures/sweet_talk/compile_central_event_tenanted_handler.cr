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

  context Catalogue, central: true, means: "the teas every tenant sells" do
    aggregate Tea, means: "one tea" do
      has name : String

      event Renamed, means: "a tea took a new name"
    end
  end

  context Ordering, follows: Catalogue, means: "choosing teas and checking out" do
    projection Names, means: "the name each tea had when it was last renamed" do
      key tea : Int64
      has name : String = ""

      whenever Catalogue::Tea::Renamed do |renamed|
        Names[renamed.tea_id.raw].name = "renamed"
      end
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
