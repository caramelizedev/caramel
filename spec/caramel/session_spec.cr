require "spec"
require "../../src/caramel"

abstract struct SessionSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

struct SessionSpecWhoami < SessionSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: session["user_id"]? || "anonymous")
  end
end

struct SessionSpecSignIn < SessionSpecAction
  contract do
    field user_id : String
  end

  def handle(contract : Contract) : Caramel::Response
    session["user_id"] = contract.user_id
    Caramel::Response.new(body: "signed in")
  end
end

struct SessionSpecSignOut < SessionSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    sign_out
    Caramel::Response.new(body: "signed out")
  end
end

module SessionSpecApp
  Caramel::Router.draw do
    get "/whoami", SessionSpecWhoami
    post "/sign-in", SessionSpecSignIn
    post "/sign-out", SessionSpecSignOut
  end
end

private SESSION_SPEC_CSRF = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")

private def session_spec_request(method : String,
                                 path : String,
                                 session : String? = nil,
                                 body : String? = nil) : Caramel::Response
  token = SESSION_SPEC_CSRF.issue
  cookies = ["#{Caramel::CSRF::COOKIE_NAME}=#{token}"]
  cookies << "#{Caramel::Session::COOKIE_NAME}=#{session}" if session
  headers = HTTP::Headers{
    "Host"         => "bookshelf.caramel",
    "Origin"       => "https://bookshelf.caramel",
    "X-CSRF-Token" => token,
    "Cookie"       => cookies.join("; "),
  }
  headers["Content-Type"] = "application/x-www-form-urlencoded" if body
  application = Caramel::Application.new(SessionSpecApp::AppRouter.new, SESSION_SPEC_CSRF)
  application.handle(HTTP::Request.new(method, path, headers, body))
end

private def session_set_cookie(response : Caramel::Response) : String?
  prefix = "#{Caramel::Session::COOKIE_NAME}="
  response.headers.get?("Set-Cookie").try &.find(&.starts_with?(prefix))
end

describe Caramel::Session do
  it "round-trips a signed session and rejects tampered, foreign and malformed values" do
    session = Caramel::Session.new(SESSION_SPEC_CSRF.derive_key("session"))
    value = session.encode({"user_id" => "42", "locale" => "en"})
    session.decode(value).should eq({"user_id" => "42", "locale" => "en"})

    payload, _, signature = value.rpartition('.')
    forged = Base64.urlsafe_encode({"user_id" => "1", "locale" => "en"}.to_json, padding: false)
    session.decode("#{forged}.#{signature}").should be_nil
    flipped = signature.sub(signature[0], signature[0] == 'A' ? 'B' : 'A')
    session.decode("#{payload}.#{flipped}").should be_nil
    foreign = Caramel::CSRF.new("x" * 64, "https://bookshelf.caramel")
    other = Caramel::Session.new(foreign.derive_key("session"))
    session.decode(other.encode({"user_id" => "42", "locale" => "en"})).should be_nil
    # A key derived for another purpose cannot sign sessions.
    misused = Caramel::Session.new(SESSION_SPEC_CSRF.derive_key("other"))
    session.decode(misused.encode({"user_id" => "42"})).should be_nil
    malformed_values = ["", ".", payload, "#{payload}.", ".#{signature}", "not base64.#{signature}"]
    malformed_values.each do |malformed|
      session.decode(malformed).should be_nil
    end
  end

  it "refuses to write a session over 4 KB and ignores oversized cookies" do
    session = Caramel::Session.new(SESSION_SPEC_CSRF.derive_key("session"))
    fits = session.encode({"note" => "x" * 2900})
    (Caramel::Session::COOKIE_NAME.bytesize + 1 + fits.bytesize).should be <= 4096
    session.decode(fits).should eq({"note" => "x" * 2900})
    expect_raises(Caramel::Session::Overflow, "exceeds 4096 bytes") do
      session.encode({"note" => "x" * 3100})
    end
    session.decode("#{fits}#{"x" * 4096}").should be_nil
  end

  it "issues an expiry-free host-only cookie only when an action changes the session" do
    anonymous = session_spec_request("GET", "/whoami")
    anonymous.body.should eq("anonymous")
    session_set_cookie(anonymous).should be_nil

    signed_in = session_spec_request("POST", "/sign-in", body: "user_id=42")
    signed_in.status.should eq(200)
    header = session_set_cookie(signed_in).not_nil!
    attributes = header.downcase
    attributes.should contain("path=/")
    attributes.should contain("secure")
    attributes.should contain("httponly")
    attributes.should contain("samesite=lax")
    attributes.should_not contain("domain=")
    attributes.should_not contain("expires=")
    attributes.should_not contain("max-age")
    value = HTTP::Cookie::Parser.parse_set_cookie(header).not_nil!.value

    known = session_spec_request("GET", "/whoami", value)
    known.body.should eq("42")
    session_set_cookie(known).should be_nil
    same = session_spec_request("POST", "/sign-in", value, "user_id=42")
    session_set_cookie(same).should be_nil
    forged = value.sub(/\.[^.]+\z/, ".forged")
    session_spec_request("GET", "/whoami", forged).body.should eq("anonymous")

    signed_out = session_spec_request("POST", "/sign-out", value)
    cleared_header = session_set_cookie(signed_out).not_nil!
    cleared = HTTP::Cookie::Parser.parse_set_cookie(cleared_header).not_nil!
    cleared.value.should eq("")
    cleared.expired?.should be_true
  end
end
