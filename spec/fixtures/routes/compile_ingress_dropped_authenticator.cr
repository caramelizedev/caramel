require "../../../src/caramel"

module Fixture
  abstract struct Api < Caramel::Action
    ingress csrf: false, authenticate: :token?

    def layout(page : Caramel::Page) : String
      page.body
    end

    private def token? : Bool
      request.headers["Authorization"]? == "Bearer token"
    end
  end

  struct NoteShow < Api
    ingress limit: 1.megabyte
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "secret")
    end
  end

  Caramel::Router.draw do
    get "/notes", NoteShow
  end
end

csrf = Caramel::CSRF.new("s" * 64, "https://example.caramel")
request = HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "example.caramel"})
Caramel::Application.new(Fixture::AppRouter.new, csrf).handle(request)
