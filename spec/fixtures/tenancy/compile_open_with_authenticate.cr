require "../../../src/caramel/tenancy"

module Fixture
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
    end
  end

  struct Home < Caramel::Action
    ingress open: true, authenticate: :member?

    contract do
    end

    def handle(contract : Contract)
      page "Home", "<p>Home</p>"
    end

    private def member? : Bool
      true
    end
  end

  Caramel::Router.draw do
    get "/", Home
    tenant Account, by: :slug do
      get "/books", Home
    end
  end
end
