require "../../../src/caramel"

class IncompleteController < Caramel::Controller
  {% for action in %w(index new create) %}
    def {{action.id}} : Caramel::Response
      Caramel::Response.new
    end
  {% end %}
end

Caramel::Router.new.resources(:books, IncompleteController, Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel"))
