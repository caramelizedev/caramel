require "../../../src/caramel"

module Fixture
  abstract struct Hook < Caramel::Action
    ingress body: :raw, csrf: false, authenticate: :signed?

    def layout(page : Caramel::Page) : String
      page.body
    end

    private def signed? : Bool
      request.headers.has_key?("X-Signature")
    end
  end

  struct FormHook < Hook
    ingress limit: 1.kilobyte
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: String.new(raw_body))
    end
  end

  Caramel::Router.draw do
    post "/hooks", FormHook
  end
end

csrf = Caramel::CSRF.new("s" * 64, "https://example.caramel")
request = HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "example.caramel"})
Caramel::Application.new(Fixture::AppRouter.new, csrf).handle(request)
