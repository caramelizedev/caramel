require "../../../src/caramel"

# A field value of the fixture's own.
struct Grams
  include Caramel::FieldValue(Int32)

  getter raw : Int32

  def initialize(@raw : Int32)
  end
end

module Fixture
  struct TeamIndex < Caramel::Action
    contract do
      field weights : Array(Grams), max: 3
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
