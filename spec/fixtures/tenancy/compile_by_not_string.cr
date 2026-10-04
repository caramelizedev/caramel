require "../../../src/caramel/tenancy"

module Fixture
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
      field seats : Int32
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
    get "/", Home
    tenant Account, by: :seats do
      get "/books", Home
    end
  end
end
