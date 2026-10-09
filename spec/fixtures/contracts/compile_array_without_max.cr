require "../../../src/caramel"

module Fixture
  struct TeamIndex < Caramel::Action
    contract do
      field tags : Array(String)
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  Caramel::Router.draw do
    get "/", TeamIndex
  end
end

Caramel::Application.new(Fixture::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://example.caramel")).handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "example.caramel"}))
