require "../../../src/caramel"

# Defines from_field but does not include Caramel::FieldValue.
struct Grams
  getter raw : Int32

  def initialize(@raw : Int32)
  end

  def self.from_field(raw : Int32, & : String ->) : self?
    new(raw)
  end
end

module Fixture
  struct TeamIndex < Caramel::Action
    contract do
      field weight : Grams
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
