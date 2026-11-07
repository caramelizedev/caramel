require "../../../src/caramel/sweet_talk/money"

module Shop
  include SweetTalk

  context Till, means: "the money a shop takes" do
    currencies %w[USD EUR], means: "a currency the till takes"
  end
end

struct Charge < Caramel::Action
  contract do
    field amount : String
  end

  def handle(contract : Contract) : Caramel::Response
    amount = Shop::Till::Amounts.parse(contract.amount, Shop::Till::Currency.usd)
    Caramel::Response.new(200, amount.to_s)
  end
end

module Charges
  Caramel::Router.draw do
    get "/charge", Charge
  end
end

# The check compares stdout, so the request is not logged.
Log.setup(:none)
csrf = Caramel::CSRF.new("s" * 64, "https://money.caramel")
application = Caramel::Application.new(Charges::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "money.caramel", "Accept" => "*/*"}
status = application.handle(HTTP::Request.new("GET", "/charge?amount=12.345", headers)).status
puts status == 422 ? "money" : "money answered #{status}"
