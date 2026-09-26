require "spec"
require "../../src/caramel/csrf"

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
