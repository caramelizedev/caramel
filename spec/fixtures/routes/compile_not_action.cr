require "../../../src/caramel"

module Fixture
  class NotAction
    struct Contract < Caramel::RequestContract
    end
  end

  Caramel::Router.draw do
    get "/", NotAction
  end
end

Caramel::Application.new(Fixture::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://example.caramel")).handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "example.caramel"}))
