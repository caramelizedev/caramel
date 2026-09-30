require "spec"
require "../../src/caramel"

private def form_request(body : String,
                         method = "POST",
                         path = "/books",
                         headers = HTTP::Headers.new) : HTTP::Request
  headers["Content-Type"] ||= "application/x-www-form-urlencoded"
  HTTP::Request.new(method, path, headers, body)
end

private alias JsonKind = Caramel::RequestInput::JsonKind

private def json_request(body : String, path = "/books") : HTTP::Request
  headers = HTTP::Headers{"Content-Type" => "application/json; charset=utf-8"}
  HTTP::Request.new("POST", path, headers, body)
end

# A request with no content type, as a raw ingress may receive one.
private def raw_request(body : String | Bytes, method = "POST") : HTTP::Request
  HTTP::Request.new(method, "/hooks", HTTP::Headers.new, body)
end

private def multipart_request(& : HTTP::FormData::Builder ->) : HTTP::Request
  io = IO::Memory.new
  builder = HTTP::FormData::Builder.new(io, "caramel-boundary")
  yield builder
  builder.finish
  headers = HTTP::Headers{"Content-Type" => builder.content_type}
  HTTP::Request.new("POST", "/uploads", headers, io.to_s)
end

describe Caramel::RequestInput do
  it "accepts a URL-encoded body of exactly the cap and refuses one byte more" do
    max = Caramel::RequestInput::MAX_FORM_BYTES
    body = "a=" + "x" * (max - 2)
    Caramel::RequestInput.read(form_request(body)).body["a"].bytesize.should eq(max - 2)
    expect_raises(Caramel::RequestInput::TooLarge) do
      Caramel::RequestInput.read(form_request(body + "x"))
    end
  end

  it "refuses a declared Content-Length over the cap before reading" do
    request = form_request("a=1")
    request.headers["Content-Length"] = (Caramel::RequestInput::MAX_FORM_BYTES + 1).to_s
    expect_raises(Caramel::RequestInput::TooLarge) { Caramel::RequestInput.read(request) }
  end

  it "refuses request bodies that are neither forms nor JSON objects" do
    expected = "Expected a URL-encoded form, multipart form or JSON object"
    {"application/xml", "application/vnd.api+json", "text/plain"}.each do |type|
      headers = HTTP::Headers{"Content-Type" => type}
      request = HTTP::Request.new("POST", "/books", headers, "{}")
      expect_raises(Caramel::RequestInput::UnsupportedMediaType, expected) do
        Caramel::RequestInput.read(request)
      end
    end
    untyped = HTTP::Request.new("POST", "/books", HTTP::Headers.new, "a=1")
    expect_raises(Caramel::RequestInput::UnsupportedMediaType) do
      Caramel::RequestInput.read(untyped)
    end
    Caramel::RequestInput.read(HTTP::Request.new("POST", "/books")).body.should be_empty
  end

  it "binds a JSON object's scalar members and records each member's JSON type" do
    body = <<-'JSON'
      {
        "title": "Dune \u00e9",
        "copies": 3,
        "price": -1.5e2,
        "signed": true,
        "note": null,
        "tags": ["sf"],
        "_method": "DELETE"
      }
      JSON
    input = Caramel::RequestInput.read(json_request(body, path: "/books?page=2"))
    input.body.should eq({
      "title"   => "Dune é",
      "copies"  => "3",
      "price"   => "-1.5e2",
      "signed"  => "true",
      "_method" => "DELETE",
    })
    input.method_override.should be_nil
    input.errors.should be_empty
    input.strict_keys.sort.should eq(%w[_method copies note page price signed tags title])
    input.source_count("note").should eq(1)

    input.json_mismatch?("title", JsonKind::String).should be_false
    input.json_mismatch?("copies", JsonKind::String).should be_true
    input.json_mismatch?("note", JsonKind::Number).should be_false
    input.json_mismatch?("tags", JsonKind::String).should be_true
    input.json_mismatch?("page", JsonKind::Number).should be_false

    Caramel::RequestInput.read(json_request("")).body.should be_empty
    huge = "123456789012345678901234567890"
    big = Caramel::RequestInput.read(json_request(%({"id": #{huge}})))
    big.body["id"].should eq(huge)
  end

  it "records duplicate JSON members and a body that is not an object as errors" do
    duplicate = Caramel::RequestInput.read(json_request(%({"title": "a", "title": "b"})))
    duplicate.body.should eq({"title" => "a"})
    duplicate.errors["_base"].should eq(["Duplicate field: title"])
    {"[]", %("text"), "1", "null"}.each do |body|
      input = Caramel::RequestInput.read(json_request(body))
      input.errors["_base"].should eq(["Expected a JSON object"])
    end
  end

  it "rejects malformed JSON, trailing data, NUL and invalid UTF-8" do
    bodies = [
      %({"a": ),
      %({} {}),
      %({"a": 1} x),
      %q({"a": "\u0000"}),
      %q({"a\u0000": 1}),
      %q({"a": "\udc00"}),
      "{\"a\": \"\xFF\"}",
      " ",
    ]
    bodies.each do |body|
      expect_raises(Caramel::RequestInput::InvalidEncoding) do
        Caramel::RequestInput.read(json_request(body))
      end
    end
  end

  it "bounds a JSON body by the route's ingress limit" do
    ingress = Caramel::Ingress.new(limit: 15)
    fits = Caramel::RequestInput.read(json_request(%({"a": "123456"})), ingress)
    fits.body["a"].should eq("123456")
    expect_raises(Caramel::RequestInput::TooLarge) do
      Caramel::RequestInput.read(json_request(%({"a": "1234567"})), ingress)
    end
  end

  it "keeps a raw ingress's body exactly as sent, of any type, and parses no controls" do
    raw = Caramel::Ingress.new(
      body: Caramel::Ingress::Body::Raw,
      limit: 64_i64,
      csrf: false,
      authenticate: "signed?",
    )
    form = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    request = HTTP::Request.new("POST", "/hooks?source=x", form, "_method=DELETE&_csrf=t")
    input = Caramel::RequestInput.read(request, raw)
    input.raw_body.should eq("_method=DELETE&_csrf=t".to_slice)
    input.body.should be_empty
    input.method_override.should be_nil
    input.csrf_token.should be_nil
    input.strict_keys.should eq(["source"])

    bytes = Bytes[0x7B, 0x00, 0xFF, 0x7D]
    Caramel::RequestInput.read(raw_request(bytes), raw).raw_body.should eq(bytes)
    Caramel::RequestInput.read(raw_request("ignored", "GET"), raw).raw_body.should be_empty
    expect_raises(Caramel::RequestInput::TooLarge) do
      Caramel::RequestInput.read(raw_request("x" * 65), raw)
    end
  end

  it "rejects invalid escapes and NUL in the body and the query" do
    ["title=%zz", "title=%00", "title=%ff"].each do |body|
      expect_raises(Caramel::RequestInput::InvalidEncoding) do
        Caramel::RequestInput.read(form_request(body))
      end
    end
    query = HTTP::Request.new("GET", "/books?q=%zz")
    expect_raises(Caramel::RequestInput::InvalidEncoding) do
      Caramel::RequestInput.read(query)
    end
  end

  it "records duplicate keys as errors and keeps transport controls out of fields" do
    body = "title=a&title=b&_csrf=token"
    path = "/books?_csrf=x&_method=PUT&page=2"
    input = Caramel::RequestInput.read(form_request(body, path: path))
    input.errors["_base"].should eq(["Duplicate field: title"])
    input.body.should eq({"title" => "a"})
    input.query.should eq({"page" => "2"})
    input.csrf_token.should eq("token")
    input.method_override.should be_nil
  end

  it "honors method overrides only on POST" do
    patch = Caramel::RequestInput.read(form_request("_method=patch"))
    patch.method_override.should eq("PATCH")
    put = Caramel::RequestInput.read(form_request("_method=DELETE", method: "PUT"))
    put.method_override.should be_nil
    expect_raises(Caramel::RequestInput::InvalidEncoding) do
      Caramel::RequestInput.read(form_request("_method=TRACE"))
    end
  end

  it "applies strict keys to GET queries only when the query is part of a write" do
    get = Caramel::RequestInput.read(HTTP::Request.new("GET", "/books?page=2"))
    get.strict_keys.should be_empty
    post = Caramel::RequestInput.read(form_request("title=a", path: "/books?page=2"))
    post.strict_keys.sort.should eq(["page", "title"])
    post.route_params = {"title" => "route"}
    post.value?("title").should eq("route")
    post.source_count("title").should eq(2)
  end

  it "streams multipart files to tempfiles and removes them on cleanup" do
    metadata = HTTP::FormData::FileMetadata.new(filename: "cover.png")
    png = HTTP::Headers{"Content-Type" => "image/png"}
    request = multipart_request do |form|
      form.field("title", "Cover")
      form.file("cover", IO::Memory.new("image bytes"), metadata, png)
    end
    input = Caramel::RequestInput.read(request)
    input.body.should eq({"title" => "Cover"})
    file = input.file?("cover").not_nil!
    file.filename.should eq("cover.png")
    file.content_type.should eq("image/png")
    file.size.should eq(11)
    File.read(file.path).should eq("image bytes")
    input.cleanup
    File.exists?(file.path).should be_false
  end

  it "deletes an oversized upload before refusing it" do
    before = Dir.glob(File.join(Dir.tempdir, "caramel-upload-*")).size
    metadata = HTTP::FormData::FileMetadata.new(filename: "big.bin")
    request = multipart_request do |form|
      form.file("cover", IO::Memory.new("x" * 2048), metadata)
    end
    expect_raises(Caramel::RequestInput::TooLarge) do
      Caramel::RequestInput.read(request, max_upload_bytes: 1024_i64)
    end
    Dir.glob(File.join(Dir.tempdir, "caramel-upload-*")).size.should eq(before)
  end

  it "bounds multipart text parts and rejects malformed multipart bodies" do
    request = multipart_request(&.field("note", "x" * 64))
    expect_raises(Caramel::RequestInput::TooLarge) do
      Caramel::RequestInput.read(request, Caramel::Ingress.new(limit: 32))
    end
    multipart = HTTP::Headers{"Content-Type" => "multipart/form-data"}
    broken = HTTP::Request.new("POST", "/uploads", multipart, "--x\r\n")
    expect_raises(Caramel::RequestInput::InvalidEncoding) { Caramel::RequestInput.read(broken) }
  end
end
