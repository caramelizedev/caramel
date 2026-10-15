require "../spec_helper"
require "openssl/hmac"

module HooksSpec
  CONTENT = {"Content-Type" => "application/json"}

  def self.signature(body : String) : String
    OpenSSL::HMAC.hexdigest(:sha256, ENV["WEBHOOK_SECRET"], body)
  end

  def self.headers(signature : String) : Hash(String, String)
    CONTENT.merge({"X-Signature" => signature})
  end
end

describe "The webhook inbox" do
  it "accepts a body with a valid signature" do
    Corretto.session do |client|
      body = %({"id":"evt_1","type":"invoice.paid"})
      signed = HooksSpec.headers(HooksSpec.signature(body))
      client.post("/hooks/inbox", body: body, headers: signed).should have_status(202)
    end
  end

  it "refuses a forged signature" do
    Corretto.session do |client|
      body = %({"id":"evt_1","type":"invoice.paid"})
      forged = HooksSpec.headers(HooksSpec.signature("{}"))
      client.post("/hooks/inbox", body: body, headers: forged).should have_status(401)
    end
  end

  it "refuses a body without a signature" do
    Corretto.session do |client|
      body = %({"id":"evt_1","type":"invoice.paid"})
      client.post("/hooks/inbox", body: body, headers: HooksSpec::CONTENT).should have_status(401)
    end
  end

  it "refuses a body over 256 KiB before checking its signature" do
    Corretto.session do |client|
      body = "x" * 262_145
      signed = HooksSpec.headers(HooksSpec.signature(body))
      client.post("/hooks/inbox", body: body, headers: signed).should have_status(413)
    end
  end
end
