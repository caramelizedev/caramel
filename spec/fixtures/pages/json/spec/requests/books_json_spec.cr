require "../spec_helper"

describe "Books as JSON" do
  it "lists and shows books, with the version as an ETag" do
    Corretto.session do |client, db|
      App::Book.create(title: "Dune", author: "Frank Herbert")
      accept = {"Accept" => "application/json"}
      listed = client.get("/books", headers: accept)
      listed.should have_status(200)
      records = JSON.parse(listed.body)["records"].as_a
      records.map(&.["title"].as_s).should eq(["Dune"])
      book = App::Book.query.first!(db)
      shown = client.get("/books/#{book.id}", headers: accept)
      shown.should have_status(200)
      shown.should have_header("ETag", %("0"))
    end
  end

  it "creates a book from JSON and updates it when If-Match holds" do
    Corretto.session do |client, _db|
      accept = {"Accept" => "application/json"}
      book = {title: "Dune", author: "Frank Herbert"}
      created = client.post("/books", json: book, headers: accept)
      created.should have_status(201)
      path = "/books/#{JSON.parse(created.body)["record"]["id"].as_i64}"
      edited = {title: "Dune Messiah", author: "Frank Herbert"}
      stale = accept.merge({"If-Match" => %("7")})
      refused = client.patch(path, json: edited, headers: stale)
      refused.should have_status(412)
      refused.body.should eq(%({"errors":{"_base":["Record changed since you loaded it"]}}))
      current = accept.merge({"If-Match" => %("0")})
      updated = client.patch(path, json: edited, headers: current)
      updated.should have_status(200)
      updated.should have_header("ETag", %("1"))
      JSON.parse(updated.body)["record"]["title"].as_s.should eq("Dune Messiah")
    end
  end

  it "answers 403, 400, 415 and 422 to writes it cannot take" do
    Corretto.session do |client, _db|
      accept = {"Accept" => "application/json"}
      book = {title: "Dune", author: "Frank Herbert"}
      forged = accept.merge({"X-CSRF-Token" => "forged"})
      client.post("/books", json: book, headers: forged).should have_status(403)
      json = accept.merge({"Content-Type" => "application/json"})
      client.post("/books", body: "{", headers: json).should have_status(400)
      text = accept.merge({"Content-Type" => "text/plain"})
      client.post("/books", body: "Dune", headers: text).should have_status(415)
      missing = client.post("/books", json: {title: "Dune"}, headers: accept)
      missing.should have_status(422)
      missing.body.should eq(%({"errors":{"author":["is required"]}}))
      array = client.post("/books", json: ["Dune"], headers: accept)
      array.should have_status(422)
      JSON.parse(array.body)["errors"]["_base"].as_a.should eq(["Expected a JSON object"])
    end
  end
end
