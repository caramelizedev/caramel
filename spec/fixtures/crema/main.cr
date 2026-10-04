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

# `APP ops …` is the ops socket's client, which the check runs from this same binary.
if ARGV.first? == "ops"
  exit(Caramel::Crema.run_command("ops", ARGV[1..]) || 2)
end

Caramel::Crema::Logging.setup
csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
app = Caramel::Application.new(CremaFixture::AppRouter.new, csrf)
server = HTTP::Server.new([app])
server.bind_unix(ARGV[0])
runtime = Caramel::Crema.start("serve", "Bookshelf", application: app)
Process.on_terminate { server.close }
puts "ready"
STDOUT.flush
server.listen
runtime.stop
