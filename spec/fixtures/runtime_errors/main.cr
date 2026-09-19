require "../../../src/caramel/application"
require "json"
require "./app/controller"

Log.setup(:error, Log::IOBackend.new(STDERR))

router = Caramel::Router.new
router.get("/broken") { |_, _| RuntimeErrorFixture.fail_request }
app = Caramel::Application.new(router, "https://bookshelf.caramel")
headers = HTTP::Headers{"Host" => "bookshelf.caramel"}
headers["HX-Request-Type"] = "partial" if ARGV.includes?("partial")
response = app.handle(HTTP::Request.new("GET", "/broken", headers))
puts({status: response.status, body: response.body, headers: response.headers.to_h}.to_json)
