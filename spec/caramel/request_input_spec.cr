require "spec"
require "../../src/caramel"

private def form_request(body : String, method = "POST", path = "/books", headers = HTTP::Headers.new) : HTTP::Request
  headers["Content-Type"] ||= "application/x-www-form-urlencoded"
  HTTP::Request.new(method, path, headers, body)
end

private def multipart_request(& : HTTP::FormData::Builder ->) : HTTP::Request
  io = IO::Memory.new
  builder = HTTP::FormData::Builder.new(io, "caramel-boundary")
  yield builder
  builder.finish
  HTTP::Request.new("POST", "/uploads", HTTP::Headers{"Content-Type" => builder.content_type}, io.to_s)
end

describe Caramel::RequestInput do
  it "accepts a URL-encoded body of exactly the cap and refuses one byte more" do
    max = Caramel::RequestInput::MAX_FORM_BYTES
    body = "a=" + "x" * (max - 2)
    Caramel::RequestInput.read(form_request(body)).body["a"].bytesize.should eq(max - 2)
    expect_raises(Caramel::RequestInput::TooLarge) { Caramel::RequestInput.read(form_request(body + "x")) }
  end

  it "refuses a declared Content-Length over the cap before reading" do
    request = form_request("a=1")
    request.headers["Content-Length"] = (Caramel::RequestInput::MAX_FORM_BYTES + 1).to_s
    expect_raises(Caramel::RequestInput::TooLarge) { Caramel::RequestInput.read(request) }
  end

  it "refuses request bodies that are not forms" do
    json = HTTP::Request.new("POST", "/books", HTTP::Headers{"Content-Type" => "application/json"}, "{}")
    expect_raises(Caramel::RequestInput::UnsupportedMediaType) { Caramel::RequestInput.read(json) }
    untyped = HTTP::Request.new("POST", "/books", HTTP::Headers.new, "a=1")
    expect_raises(Caramel::RequestInput::UnsupportedMediaType) { Caramel::RequestInput.read(untyped) }
    Caramel::RequestInput.read(HTTP::Request.new("POST", "/books")).body.should be_empty
  end

  it "rejects invalid escapes and NUL in the body and the query" do
    ["title=%zz", "title=%00", "title=%ff"].each do |body|
      expect_raises(Caramel::RequestInput::InvalidEncoding) { Caramel::RequestInput.read(form_request(body)) }
    end
    expect_raises(Caramel::RequestInput::InvalidEncoding) { Caramel::RequestInput.read(HTTP::Request.new("GET", "/books?q=%zz")) }
  end

  it "records duplicate keys as errors and keeps transport controls out of fields" do
    input = Caramel::RequestInput.read(form_request("title=a&title=b&_csrf=token", path: "/books?_csrf=x&_method=PUT&page=2"))
    input.errors["_base"].should eq(["Duplicate field: title"])
    input.body.should eq({"title" => "a"})
    input.query.should eq({"page" => "2"})
    input.csrf_token.should eq("token")
    input.method_override.should be_nil
  end

  it "honors method overrides only on POST" do
    Caramel::RequestInput.read(form_request("_method=patch")).method_override.should eq("PATCH")
    Caramel::RequestInput.read(form_request("_method=DELETE", method: "PUT")).method_override.should be_nil
    expect_raises(Caramel::RequestInput::InvalidEncoding) { Caramel::RequestInput.read(form_request("_method=TRACE")) }
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
    request = multipart_request do |form|
      form.field("title", "Cover")
      form.file("cover", IO::Memory.new("image bytes"), HTTP::FormData::FileMetadata.new(filename: "cover.png"), HTTP::Headers{"Content-Type" => "image/png"})
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
    request = multipart_request do |form|
      form.file("cover", IO::Memory.new("x" * 2048), HTTP::FormData::FileMetadata.new(filename: "big.bin"))
    end
    expect_raises(Caramel::RequestInput::TooLarge) { Caramel::RequestInput.read(request, max_upload_bytes: 1024_i64) }
    Dir.glob(File.join(Dir.tempdir, "caramel-upload-*")).size.should eq(before)
  end

  it "bounds multipart text parts and rejects malformed multipart bodies" do
    request = multipart_request(&.field("note", "x" * 64))
    expect_raises(Caramel::RequestInput::TooLarge) { Caramel::RequestInput.read(request, max_form_bytes: 32) }
    broken = HTTP::Request.new("POST", "/uploads", HTTP::Headers{"Content-Type" => "multipart/form-data"}, "--x\r\n")
    expect_raises(Caramel::RequestInput::InvalidEncoding) { Caramel::RequestInput.read(broken) }
  end
end
