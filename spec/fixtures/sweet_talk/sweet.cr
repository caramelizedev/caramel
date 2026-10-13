require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    value Tins, Int32, at_least: 0, means: "a count of tins on the shelf"

    aggregate Tea, means: "one tea we sell" do
      has name : String

      to rename(name : String) do
        @name = name
      end
    end
  end
end

struct Count < Caramel::Action
  contract do
    field tins : Int32
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(200, Shop::Catalogue::Tins.new(contract.tins).to_s)
  end
end

module Sweet
  Caramel::Router.draw do
    get "/count", Count
  end
end

# Never runs, but compiles the command in.
if ARGV.includes?("--never")
  Shop::Catalogue::Tea.find(Shop::Catalogue::Tea::Id.new(1_i64)).rename "Sencha"
end

# The check compares stdout, so the request is not logged.
Log.setup(:none)
csrf = Caramel::CSRF.new("s" * 64, "https://sweet.caramel")
application = Caramel::Application.new(Sweet::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "sweet.caramel", "Accept" => "*/*"}
status = application.handle(HTTP::Request.new("GET", "/count?tins=-1", headers)).status
puts status == 422 ? "sweet" : "sweet answered #{status}"
