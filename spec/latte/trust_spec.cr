require "spec"
require "file_utils"
require "../../src/latte/trust"

describe Caramel::Latte::Trust do
  it "refuses to install trust while an authority key is readable by others" do
    root = File.join("/private/tmp", "latte-trust-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    # ameba:disable Lint/UselessAssign -- read by the ensure below
    registry = nil
    begin
      registry = Caramel::Latte::Registry.new(root)
      proxy = Caramel::Latte::Proxy.new(registry, https_port: 18443, http_port: 18080)
      authority = File.dirname(proxy.root_certificate)
      FileUtils.mkdir_p(authority, 0o700)
      File.write(proxy.root_certificate, "not a certificate", perm: 0o600)
      key = File.join(authority, "root.key")
      File.write(key, "not a key", perm: 0o640)
      trust = Caramel::Latte::Trust.new(registry.paths, proxy)

      error = expect_raises(Caramel::Latte::PublicError, "#{key} must be a file you own") do
        trust.install
      end
      error.code.should eq("ca_key_exposed")
      File.exists?(File.join(root, "trust")).should be_false
    ensure
      FileUtils.rm_rf(registry.paths.run_dir) if registry
      FileUtils.rm_rf(root)
    end
  end
end
