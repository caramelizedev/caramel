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

struct SessionSpecNote < SessionSpecAction
  contract do
    field note : String
  end

  def handle(contract : Contract) : Caramel::Response
    session["note"] = contract.note
    Caramel::Response.new(body: "kept #{session["note"].bytesize}")
  end
end

# Rescues the write to show the raise comes from it, not from encoding the
# response's cookie.
struct SessionSpecNoteRescued < SessionSpecAction
  contract do
    field note : String
  end

  def handle(contract : Contract) : Caramel::Response
    session["note"] = contract.note
    Caramel::Response.new(body: "kept")
  rescue Caramel::Session::Overflow
    Caramel::Response.new(body: "refused; session holds #{session.keys.join(",")}")
  end
end

module SessionSpecApp
  Caramel::Router.draw do
    get "/whoami", SessionSpecWhoami
    post "/sign-in", SessionSpecSignIn
    post "/sign-out", SessionSpecSignOut
    post "/note", SessionSpecNote
    post "/note-rescued", SessionSpecNoteRescued
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

private def session_spec_session(max_age = Caramel::Session::MAX_AGE) : Caramel::Session
  Caramel::Session.new(SESSION_SPEC_CSRF.derive_keys("session"), max_age)
end

describe Caramel::Session do
  it "round-trips a signed session and rejects tampered, foreign and malformed values" do
    session = session_spec_session
    value = session.encode({"user_id" => "42", "locale" => "en"})
    session.decode(value).should eq({"user_id" => "42", "locale" => "en"})

    signed, _, signature = value.rpartition('.')
    payload, _, issued = signed.rpartition('.')
    forged = Base64.urlsafe_encode({"user_id" => "1", "locale" => "en"}.to_json, padding: false)
    session.decode("#{forged}.#{issued}.#{signature}").should be_nil
    flipped = signature.sub(signature[0], signature[0] == 'A' ? 'B' : 'A')
    session.decode("#{signed}.#{flipped}").should be_nil
    session.decode("#{payload}.#{issued.to_i64 - 1}.#{signature}").should be_nil
    foreign = Caramel::CSRF.new("x" * 64, "https://bookshelf.caramel")
    other = Caramel::Session.new(foreign.derive_keys("session"))
    session.decode(other.encode({"user_id" => "42", "locale" => "en"})).should be_nil
    # A key derived for another purpose cannot sign sessions.
    misused = Caramel::Session.new(SESSION_SPEC_CSRF.derive_keys("other"))
    session.decode(misused.encode({"user_id" => "42"})).should be_nil
    malformed_values = [
      "", ".", "..", payload, signed, "#{signed}.", ".#{issued}.#{signature}",
      "#{payload}..#{signature}", "#{payload}.now.#{signature}",
      "not base64.#{issued}.#{signature}",
    ]
    malformed_values.each do |malformed|
      session.decode(malformed).should be_nil
    end
  end

  it "reads a cookie without an issue time, the format before 0.20.0, as empty" do
    session = session_spec_session
    payload = Base64.urlsafe_encode({"user_id" => "42"}.to_json, padding: false)
    key = SESSION_SPEC_CSRF.derive_keys("session").first
    digest = OpenSSL::HMAC.digest(:sha256, key, payload)
    session.decode("#{payload}.#{Base64.urlsafe_encode(digest, padding: false)}").should be_nil
  end

  it "reads a cookie older than max_age as empty, and one from the future beyond the skew" do
    session = session_spec_session
    signed_at = Time.utc(2026, 10, 1, 12, 0, 0)
    cookie = session.encode({"user_id" => "42"}, signed_at)
    session.decode(cookie, signed_at + 14.days).should eq({"user_id" => "42"})
    session.decode(cookie, signed_at + 14.days + 1.second).should be_nil
    session.decode(cookie, signed_at - 1.minute).should eq({"user_id" => "42"})
    session.decode(cookie, signed_at - 1.minute - 1.second).should be_nil

    hour = session_spec_session(1.hour)
    hourly = hour.encode({"user_id" => "42"}, signed_at)
    hour.decode(hourly, signed_at + 1.hour).should eq({"user_id" => "42"})
    hour.decode(hourly, signed_at + 1.hour + 1.second).should be_nil
  end

  it "reads a cookie signed under one APP_SECRET as empty under another" do
    secret_a = Caramel::CSRF.new("a" * 64, "https://bookshelf.caramel")
    secret_b = Caramel::CSRF.new("b" * 64, "https://bookshelf.caramel")
    cookie = Caramel::Session.new(secret_a.derive_keys("session")).encode({"user_id" => "42"})
    same = Caramel::Session.new(secret_a.derive_keys("session"))
    same.decode(cookie).should eq({"user_id" => "42"})
    Caramel::Session.new(secret_b.derive_keys("session")).decode(cookie).should be_nil
  end

  it "reads a cookie from a previous APP_SECRET and re-signs a change under the current one" do
    origin = "https://bookshelf.caramel"
    old = Caramel::Session.new(Caramel::CSRF.new("a" * 64, origin).derive_keys("session"))
    cookie = old.encode({"user_id" => "42"})
    rotated = Caramel::CSRF.new("b" * 64, origin, ["a" * 64])
    session = Caramel::Session.new(rotated.derive_keys("session"))
    session.decode(cookie).should eq({"user_id" => "42"})
    current_only = Caramel::Session.new(Caramel::CSRF.new("b" * 64, origin).derive_keys("session"))
    current_only.decode(cookie).should be_nil
    current_only.decode(session.encode({"user_id" => "42"})).should eq({"user_id" => "42"})

    application = Caramel::Application.new(SessionSpecApp::AppRouter.new, rotated)
    token = rotated.issue
    headers = HTTP::Headers{
      "Host"         => "bookshelf.caramel",
      "Origin"       => origin,
      "X-CSRF-Token" => token,
      "Cookie"       => "#{Caramel::CSRF::COOKIE_NAME}=#{token}; " \
                  "#{Caramel::Session::COOKIE_NAME}=#{cookie}",
      "Content-Type" => "application/x-www-form-urlencoded",
    }
    changed = application.handle(HTTP::Request.new("POST", "/sign-in", headers, "user_id=7"))
    header = session_set_cookie(changed).not_nil!
    value = HTTP::Cookie::Parser.parse_set_cookie(header).not_nil!.value
    current_only.decode(value).should eq({"user_id" => "7"})
  end

  # The cookie for {"note" => "x" * k} is 22 + 1 + base64(11 + k) + 1 + 10 + 1 + 43
  # bytes. Unpadded base64 skips some lengths: k = 3002 takes exactly 4096 bytes
  # and k = 3003 takes 4097.
  it "computes the cookie's size without encoding it, to the byte at the limit" do
    session = session_spec_session
    (2992..3002).each do |length|
      data = {"note" => "x" * length}
      actual = Caramel::Session::COOKIE_NAME.bytesize + 1 + session.encode(data).bytesize
      Caramel::Session.cookie_bytes(data).should eq(actual)
      Caramel::Session.fits?(data).should be_true
    end
    Caramel::Session.cookie_bytes({"note" => "x" * 3002}).should eq(4096)
    Caramel::Session.cookie_bytes({"note" => "x" * 3003}).should eq(4097)
    Caramel::Session.fits?({"note" => "x" * 3003}).should be_false
    expect_raises(Caramel::Session::Overflow, "exceeds 4096 bytes") do
      session.encode({"note" => "x" * 3003})
    end
  end

  it "refuses a write past 4 KB at the write and keeps the session as it was" do
    data = Caramel::Session::Data.new({"user_id" => "42", "note" => "short"})
    expect_raises(Caramel::Session::Overflow, "exceeds 4096 bytes") do
      data["note"] = "x" * 3100
    end
    data["note"].should eq("short")
    expect_raises(Caramel::Session::Overflow) { data["draft"] = "x" * 3100 }
    data.has_key?("draft").should be_false
    expect_raises(Caramel::Session::Overflow) { data.update("note") { "x" * 3100 } }
    data["note"].should eq("short")
    expect_raises(Caramel::Session::Overflow) { data.merge!({"draft" => "x" * 3100}) }
    data.has_key?("draft").should be_false
    expect_raises(Caramel::Session::Overflow) { data.put("draft", "x" * 3100) { } }
    data.has_key?("draft").should be_false
    expect_raises(Caramel::Session::Overflow) { data.put_if_absent("draft") { "x" * 3100 } }
    data.has_key?("draft").should be_false
    expect_raises(Caramel::Session::Overflow) { data.transform_values! { |_| "x" * 3100 } }
    data.should eq({"user_id" => "42", "note" => "short"})
    data["note"] = "x" * 2975
    data["note"].bytesize.should eq(2975)
  end

  it "ignores an oversized cookie" do
    session = session_spec_session
    fits = session.encode({"note" => "x" * 2900})
    session.decode("#{fits}#{"x" * 4096}").should be_nil
  end

  it "answers 500 with no cookie when an action's session write overflows" do
    kept = session_spec_request("POST", "/note", body: "note=#{"x" * 3002}")
    kept.status.should eq(200)
    kept.body.should eq("kept 3002")
    session_set_cookie(kept).should_not be_nil

    refused = session_spec_request("POST", "/note", body: "note=#{"x" * 3003}")
    refused.status.should eq(500)
    session_set_cookie(refused).should be_nil

    rescued = session_spec_request("POST", "/note-rescued", body: "note=#{"x" * 3003}")
    rescued.status.should eq(200)
    rescued.body.should eq("refused; session holds ")
    session_set_cookie(rescued).should be_nil
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

describe "Caramel.previous_secrets" do
  it "splits APP_SECRET_PREVIOUS on commas and refuses a secret under 32 bytes" do
    Caramel.previous_secrets({} of String => String).should eq([] of String)
    Caramel.previous_secrets({"APP_SECRET_PREVIOUS" => ""}).should eq([] of String)
    two = {"APP_SECRET_PREVIOUS" => "#{"a" * 64}, #{"b" * 32},"}
    Caramel.previous_secrets(two).should eq(["a" * 64, "b" * 32])
    expect_raises(ArgumentError, "APP_SECRET_PREVIOUS") do
      Caramel.previous_secrets({"APP_SECRET_PREVIOUS" => "#{"a" * 64},short"})
    end
  end
end
