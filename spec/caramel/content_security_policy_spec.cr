require "spec"
require "../../src/caramel/content_security_policy"

private DEFAULT_POLICY = "default-src 'self'; script-src 'self'; style-src 'self'; " \
                         "img-src 'self' data:; base-uri 'self'; form-action 'self'; " \
                         "frame-ancestors 'none'; object-src 'none'"

describe Caramel::ContentSecurityPolicy do
  it "writes the default policy Caramel has always sent" do
    Caramel::ContentSecurityPolicy.default.to_s.should eq(DEFAULT_POLICY)
  end

  it "starts a missing -src directive from default-src, so 'self' stays" do
    policy = Caramel::ContentSecurityPolicy.default.add("connect-src", "https://api.example")
    policy.to_s.should contain("connect-src 'self' https://api.example")
  end

  it "adds to an existing directive in order and never twice" do
    policy = Caramel::ContentSecurityPolicy.default
    policy.add("script-src", "https://a.example", "https://b.example")
    policy.add("script-src", "https://a.example")
    policy.to_s.should contain("script-src 'self' https://a.example https://b.example;")
  end

  it "drops 'none' when a source is added" do
    policy = Caramel::ContentSecurityPolicy.default
    policy.add("frame-ancestors", "https://partner.example")
    policy.to_s.should contain("frame-ancestors https://partner.example;")
  end

  it "replaces a directive with set, which may take no source" do
    policy = Caramel::ContentSecurityPolicy.default
    policy.set("img-src", "https://cdn.example").set("upgrade-insecure-requests")
    policy.to_s.should contain("img-src https://cdn.example;")
    policy.to_s.should end_with("object-src 'none'; upgrade-insecure-requests")
  end

  it "removes a directive with delete" do
    policy = Caramel::ContentSecurityPolicy.default.delete("object-src")
    policy.to_s.should_not contain("object-src")
  end

  it "changes a dup without touching the original" do
    original = Caramel::ContentSecurityPolicy.default
    original.dup.add("script-src", "https://a.example").delete("img-src")
    original.to_s.should eq(DEFAULT_POLICY)
  end

  it "refuses a directive name or source that could end the header's structure" do
    policy = Caramel::ContentSecurityPolicy.default
    expect_raises(ArgumentError, "lowercase words joined by hyphens") do
      policy.add("Script-Src", "https://a.example")
    end
    expect_raises(ArgumentError, "printable ASCII without spaces") do
      policy.add("script-src", "https://a.example; script-src *")
    end
    expect_raises(ArgumentError, "printable ASCII without spaces") do
      policy.set("img-src", "a,b")
    end
  end

  it "refuses an add with no source" do
    expect_raises(ArgumentError, "add needs at least one source") do
      Caramel::ContentSecurityPolicy.default.add("script-src")
    end
  end
end
