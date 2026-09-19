require "spec"
require "../../src/caramel/form"
require "../../src/caramel/csrf"

describe Caramel::Form do
  it "decodes only declared fields and preserves invalid values" do
    form = Caramel::Form.new("book%5Btitle%5D=Hello+World&book[author]=A%26B", "book", ["title", "author"])
    form.valid?.should be_true
    form["title"].should eq("Hello World")
    form["author"].should eq("A&B")
    missing = Caramel::Form.new("book[title]=", "book", ["title", "author"])
    missing.valid?.should be_false
    missing["title"].should eq("")
  end

  it "rejects duplicate, undeclared and foreign-envelope fields" do
    ["book[title]=a&book[title]=b&book[author]=c", "book[title]=a&book[author]=b&book[admin]=true", "book[title]=a&book[author]=b&user[id]=1"].each do |body|
      Caramel::Form.new(body, "book", ["title", "author"]).valid?.should be_false
    end
  end

  it "rejects invalid encodings and oversized bodies" do
    expect_raises(Caramel::Form::InvalidEncoding) { Caramel::Form.new("book[title]=%zz", "book", ["title"]) }
    expect_raises(Caramel::Form::InvalidEncoding) { Caramel::Form.new("book[title]=%00", "book", ["title"]) }
    expect_raises(Caramel::Form::TooLarge) { Caramel::Form.new("a" * 65_537, "book", ["title"]) }
  end

  it "bounds streamed request bodies before parsing and checks the media type" do
    request = HTTP::Request.new("POST", "/books", HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8"}, "book[title]=Hello")
    Caramel::Form.read(request, "book", ["title"])["title"].should eq("Hello")
    oversized = HTTP::Request.new("POST", "/books", HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}, "a" * 65_537)
    expect_raises(Caramel::Form::TooLarge) { Caramel::Form.read(oversized, "book", ["title"]) }
    json = HTTP::Request.new("POST", "/books", HTTP::Headers{"Content-Type" => "application/json"}, "{}")
    expect_raises(Caramel::Form::UnsupportedMediaType) { Caramel::Form.read(json, "book", ["title"]) }
  end

  it "supports explicitly optional fields for a shared update/delete endpoint" do
    form = Caramel::Form.new("_method=DELETE", "book", ["title", "author"], required_fields: [] of String)
    form.valid?.should be_true
    form.method("POST").should eq("DELETE")
  end

  it "allows only safe POST method overrides" do
    form = Caramel::Form.new("_method=DELETE&book[title]=a", "book", ["title"])
    form.method("POST").should eq("DELETE")
    form.method("GET").should eq("GET")
    Caramel::Form.new("_method=TRACE", "book", [] of String).valid?.should be_false
  end
end

describe Caramel::CSRF do
  it "accepts only a signed unexpired token and the exact configured origin" do
    csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
    token = csrf.issue
    headers = HTTP::Headers{"Origin" => "https://bookshelf.caramel", "Cookie" => "__Host-caramel_csrf=#{token}"}
    request = HTTP::Request.new("POST", "/books", headers)
    csrf.valid?(request, token).should be_true
    csrf.valid?(request, "forged").should be_false
    other = Caramel::CSRF.new("x" * 64, "https://bookshelf.caramel").issue
    request.headers["Cookie"] = "__Host-caramel_csrf=#{other}"
    # Build a fresh request because Crystal memoizes parsed cookies.
    forged = HTTP::Request.new("POST", "/", request.headers.dup)
    csrf.valid?(forged, other).should be_false
    request.headers["Origin"] = "https://evil.bookshelf.caramel"
    csrf.valid?(request, token).should be_false
    request.headers.delete("Origin")
    csrf.valid?(request, token).should be_false
  end

  it "rejects expired tokens and uses secure host-only cookies" do
    csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
    expired = csrf.issue(Time.utc - 2.days)
    request = HTTP::Request.new("POST", "/", HTTP::Headers{"Origin" => "https://bookshelf.caramel", "Cookie" => "__Host-caramel_csrf=#{expired}"})
    csrf.valid?(request, expired).should be_false
    cookie = csrf.cookie(csrf.issue).to_set_cookie_header
    cookie.should contain("Secure")
    cookie.should contain("HttpOnly")
    cookie.should contain("SameSite=Lax")
    cookie.downcase.should contain("path=/")
    cookie.downcase.should_not contain("domain=")
    expect_raises(ArgumentError) { Caramel::CSRF.new("short", "https://bookshelf.caramel") }
    expect_raises(ArgumentError) { Caramel::CSRF.new("s" * 64, "http://bookshelf.caramel") }
  end
end
