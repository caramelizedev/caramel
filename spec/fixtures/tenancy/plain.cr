# An application without caramel/tenancy; scripts/checks/tenancy.cr builds
# it and checks that its binary holds none of the tenancy code.
require "../../../src/caramel"

module TenancyZeroCost
  struct Book < SugarORM::Schema
    schema "books" do
      field id : Int64, primary: true
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
    get "/books", Books
  end
end

csrf = Caramel::CSRF.new("s" * 64, "https://zero.caramel")
app = Caramel::Application.new(TenancyZeroCost::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "zero.caramel"}
{"/", "/Nope"}.each do |path|
  puts app.handle(HTTP::Request.new("GET", path, headers)).status
end
