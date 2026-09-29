require "../../../src/caramel"

module Fixture
  struct Hook < Caramel::Action
    ingress limit: 1.kilobyte
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: String.new(raw_body))
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  Caramel::Router.draw do
    post "/hooks", Hook
  end
end

Caramel::Application.new(Fixture::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://example.caramel")).handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "example.caramel"}))
