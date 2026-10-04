require "../../../src/caramel"

abstract struct CremaFixtureAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

struct CremaFixtureShow < CremaFixtureAction
  contract do
    field id : Int64, min: 1
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "book #{contract.id}")
  end
end

struct CremaFixtureBroken < CremaFixtureAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    raise KeyError.new("private-detail do-not-log")
  end
end

module CremaFixture
  Caramel::Router.draw do
    get "/books/:id", CremaFixtureShow
    get "/broken", CremaFixtureBroken
  end
end

Caramel::Crema::Logging.setup
csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
app = Caramel::Application.new(CremaFixture::AppRouter.new, csrf)
server = HTTP::Server.new([app])
server.bind_unix(ARGV[0])
Process.on_terminate { server.close }
puts "ready"
STDOUT.flush
server.listen
