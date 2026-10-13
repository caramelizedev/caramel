require "../../../src/caramel"

struct Hello < Caramel::Action
  contract do
    field name : String
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(200, "Hello, #{contract.name}")
  end
end

module Plain
  Caramel::Router.draw do
    get "/hello", Hello
  end
end

# The check compares stdout, so the request is not logged.
Log.setup(:none)
csrf = Caramel::CSRF.new("s" * 64, "https://plain.caramel")
application = Caramel::Application.new(Plain::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "plain.caramel", "Accept" => "*/*"}
status = application.handle(HTTP::Request.new("GET", "/hello?name=Ada", headers)).status
puts status == 200 ? "plain" : "plain answered #{status}"
