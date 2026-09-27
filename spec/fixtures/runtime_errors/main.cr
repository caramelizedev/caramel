require "../../../src/caramel/application"
require "../../../src/caramel/action"
require "../../../src/caramel/http/router"
require "json"
require "./app/controller"

Log.setup(:error, Log::IOBackend.new(STDERR))

struct BrokenAction < Caramel::Action
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    RuntimeErrorFixture.fail_request
  end

  def layout(page : Caramel::Page) : String
    page.body
  end
end

module RuntimeFixture
  Caramel::Router.draw do
    get "/broken", BrokenAction
  end
end

app = Caramel::Application.new(RuntimeFixture::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel"))
headers = HTTP::Headers{"Host" => "bookshelf.caramel"}
headers["HX-Request-Type"] = "partial" if ARGV.includes?("partial")
response = app.handle(HTTP::Request.new("GET", "/broken", headers))
puts({status: response.status, body: response.body, headers: response.headers.to_h}.to_json)
