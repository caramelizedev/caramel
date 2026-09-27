require "../../../src/caramel"

struct OutsideView < Caramel::Action
  contract do
  end

  def handle(contract : Contract)
    page "Nope", view("anything")
  end

  def layout(page : Caramel::Page) : String
    page.body
  end
end

module OutsideViewApp
  Caramel::Router.draw do
    get "/", OutsideView
  end
end

Caramel::Application.new(OutsideViewApp::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://example.caramel")).handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "example.caramel"}))
