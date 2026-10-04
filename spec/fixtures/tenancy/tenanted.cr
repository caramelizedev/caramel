# The application plain.cr is, with caramel/tenancy and a tenant route;
# scripts/checks/tenancy.cr checks that only this binary holds tenancy code.
require "../../../src/caramel/tenancy"

module TenancyZeroCost
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
    end
  end

  struct Book < SugarORM::Schema
    schema "books" do
      field id : Int64, primary: true
      tenant account : Account
      field title : String
    end
  end

  struct Home < Caramel::Action
    contract do
    end

    def handle(contract : Contract)
      page "Home", "<p>Home</p>"
    end
  end

  struct Books < Caramel::Action
    contract do
    end

    def handle(contract : Contract)
      page "Books", "<p>#{Book.query.count}</p>"
    end
  end

  Caramel::Router.draw do
    get "/", Home
    tenant Account, by: :slug do
      get "/books", Books
    end
  end
end

csrf = Caramel::CSRF.new("s" * 64, "https://zero.caramel")
app = Caramel::Application.new(TenancyZeroCost::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "zero.caramel"}
{"/", "/Nope"}.each do |path|
  puts app.handle(HTTP::Request.new("GET", path, headers)).status
end
