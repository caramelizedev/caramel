require "../../../src/caramel/tenancy"

module Fixture
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
    end
  end

  struct Home < Caramel::Action
    contract do
    end

    def handle(contract : Contract)
      page "Home", "<p>Home</p>"
    end
  end

  struct Page < Caramel::Action
    contract do
      field name : String
    end

    def handle(contract : Contract)
      page contract.name, "<p>Page</p>"
    end
  end

  Caramel::Router.draw do
    get "/", Home
    get "/:name", Page
    tenant Account, by: :slug do
      get "/books", Home
    end
  end
end
