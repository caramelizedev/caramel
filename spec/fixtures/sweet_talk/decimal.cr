require "../../../src/caramel/sweet_talk/decimal"

module Shop
  include SweetTalk
  ids Int64

  context Treasury, means: "the money we keep" do
    value Rate, Decimal(20, 8), at_least: "0", means: "a yearly rate"
  end
end

struct Quote < Caramel::Action
  contract do
    field rate : String
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(200, Shop::Treasury::Rate.new(contract.rate).to_s)
  end
end

module Rates
  Caramel::Router.draw do
    get "/quote", Quote
  end
end

# The check compares stdout, so the request is not logged.
Log.setup(:none)
csrf = Caramel::CSRF.new("s" * 64, "https://decimal.caramel")
application = Caramel::Application.new(Rates::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "decimal.caramel", "Accept" => "*/*"}
status = application.handle(HTTP::Request.new("GET", "/quote?rate=1e3", headers)).status
puts status == 422 ? "decimal" : "decimal answered #{status}"
