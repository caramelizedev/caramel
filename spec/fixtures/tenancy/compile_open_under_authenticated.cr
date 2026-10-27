require "../../../src/caramel/tenancy"

module Fixture
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
    end
  end

  abstract struct Base < Caramel::Action
    ingress authenticate: :member?

    private def member? : Bool
      true
    end
  end

  # Drops the parent's authenticator by opening the route.
  struct Home < Base
    ingress open: true

    contract do
    end

    def handle(contract : Contract)
      page "Home", "<p>Home</p>"
    end
  end

  Caramel::Router.draw do
    get "/", Home
    tenant Account, by: :slug do
      get "/books", Home
    end
  end
end
