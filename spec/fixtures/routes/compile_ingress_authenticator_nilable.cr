require "../../../src/caramel"

module Fixture
  struct Hook < Caramel::Action
    ingress csrf: false, authenticate: :signed?
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end

    private def signed? : Bool?
      request.headers.has_key?("X-Signature") || nil
    end
  end

  Caramel::Router.draw do
    post "/hooks", Hook
  end
end

csrf = Caramel::CSRF.new("s" * 64, "https://example.caramel")
request = HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "example.caramel"})
Caramel::Application.new(Fixture::AppRouter.new, csrf).handle(request)
