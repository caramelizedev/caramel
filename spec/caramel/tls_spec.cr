require "spec"
require "../../src/caramel/tls"

describe Caramel::TLS do
  it "makes a client context without Crystal's legacy SSL_OP_ALL options" do
    options = Caramel::TLS.client_context.options.value.to_u64
    (options & Caramel::TLS::LEGACY_OPTIONS.value.to_u64).should eq(0_u64)
  end

  it "changes nothing but those options" do
    default = OpenSSL::SSL::Context::Client.new.options.value.to_u64
    legacy = Caramel::TLS::LEGACY_OPTIONS.value.to_u64
    Caramel::TLS.client_context.options.value.to_u64.should eq(default & ~legacy)
  end

  it "gives an https URI a context and an http URI none" do
    secure = URI.parse("https://api.example.test/v1")
    Caramel::TLS.client_context(secure).should be_a(OpenSSL::SSL::Context::Client)
    Caramel::TLS.client_context(URI.parse("http://127.0.0.1:4318")).should be_nil
  end
end
