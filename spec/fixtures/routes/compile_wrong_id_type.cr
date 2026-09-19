require "../../../src/caramel"

class WrongIDController < Caramel::Controller
  {% for action in %w(index new create) %}
    def {{action.id}} : Caramel::Response
      Caramel::Response.new
    end
  {% end %}

  def show(id : String) : Caramel::Response
    Caramel::Response.new
  end
end

Caramel::Router.new.resources(:books, WrongIDController, Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel"))
