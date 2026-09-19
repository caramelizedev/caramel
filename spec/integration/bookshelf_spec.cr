require "spec"
require "../../examples/bookshelf/config/application"

url = ENV["CARAMEL_OWNED_BOOKSHELF_URL"]? || raise "Run scripts/integration; no owned Bookshelf database provided"

describe "Bookshelf requests" do
  it "provides complete CRUD, form validation, escaping and htmx responses" do
    db = Caramel::Database.open(url)
    begin
      Caramel::Migrator.new(db, Bookshelf::MIGRATIONS).migrate
      app = Bookshelf::App.new(db, "s" * 64).application
      headers = HTTP::Headers{"Host" => "bookshelf.caramel"}
      page = app.handle(HTTP::Request.new("GET", "/books", headers))
      page.status.should eq(200)
      page.body.should contain("Your next chapter")
      page.body.should contain("/assets/htmx-4.0.0.min.js")
      token = page.headers["Set-Cookie"].split(';').first.split('=', 2)[1]
      write_headers = HTTP::Headers{"Host" => "bookshelf.caramel", "Origin" => "https://bookshelf.caramel", "Content-Type" => "application/x-www-form-urlencoded", "Cookie" => "__Host-caramel_csrf=#{token}"}
      payload = URI::Params.build { |p| p.add("_csrf", token); p.add("book[title]", "<script>alert(1)</script>"); p.add("book[author]", "Ursula Le Guin") }
      app.handle(HTTP::Request.new("POST", "/books", write_headers, payload)).status.should eq(303)
      id = db.query_one("SELECT id FROM books LIMIT 1", as: Int64)
      show = app.handle(HTTP::Request.new("GET", "/books/#{id}", headers))
      show.body.should contain("&lt;script&gt;alert(1)&lt;/script&gt;")
      show.body.should_not contain("<script>alert(1)</script>")
      show.body.should contain("Ursula Le Guin")
      show_partial_headers = headers.dup
      show_partial_headers["HX-Request-Type"] = "partial"
      partial_show = app.handle(HTTP::Request.new("GET", "/books/#{id}", show_partial_headers))
      partial_show.body.should start_with("<title>&lt;script&gt;alert(1)&lt;/script&gt; · Bookshelf</title>")
      app.handle(HTTP::Request.new("GET", "/books/#{id}/edit", headers)).status.should eq(200)
      invalid = URI::Params.build { |p| p.add("_csrf", token); p.add("book[title]", ""); p.add("book[author]", "Retained author") }
      rejected = app.handle(HTTP::Request.new("POST", "/books", write_headers, invalid))
      rejected.status.should eq(422)
      rejected.body.should contain("Retained author")
      rejected.body.should contain("Title is required")
      update = URI::Params.build { |p| p.add("_csrf", token); p.add("_method", "PATCH"); p.add("book[title]", "A Wizard of Earthsea"); p.add("book[author]", "Ursula Le Guin") }
      app.handle(HTTP::Request.new("POST", "/books/#{id}", write_headers, update)).status.should eq(303)
      db.query_one("SELECT title FROM books WHERE id = $1", id, as: String).should eq("A Wizard of Earthsea")
      partial_headers = headers.dup
      partial_headers["HX-Request-Type"] = "partial"
      partial = app.handle(HTTP::Request.new("GET", "/books", partial_headers))
      partial.body.should contain("A Wizard of Earthsea")
      partial.body.should_not contain("<!DOCTYPE")
      partial.headers["Vary"].should eq("HX-Request-Type")
      forged = write_headers.dup
      forged["Origin"] = "https://neighbor.caramel"
      deletion = URI::Params.build { |p| p.add("_csrf", token); p.add("_method", "DELETE") }
      app.handle(HTTP::Request.new("POST", "/books/#{id}", forged, deletion)).status.should eq(403)
      db.query_one("SELECT count(*) FROM books", as: Int64).should eq(1)
      app.handle(HTTP::Request.new("POST", "/books/#{id}", write_headers, deletion)).status.should eq(303)
      app.handle(HTTP::Request.new("GET", "/books/#{id}", headers)).status.should eq(404)
      app.handle(HTTP::Request.new("GET", "/config/application.cr", headers)).status.should eq(404)
    ensure
      db.close
    end
  end
end
