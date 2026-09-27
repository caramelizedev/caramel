require "spec"
require "file_utils"
require "socket"
require "../../src/latte/dns"
require "../../src/latte/proxy"

describe "Latte network configuration" do
  it "registers exact hosts and produces isolated local HTTPS configuration" do
    root = File.join("/private/tmp", "latte-network-config-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    paths = nil
    begin
      registry = Caramel::Latte::Registry.new(root)
      paths = registry.paths
      %w(bookshelf notes).each do |name|
        directory = File.join(root, name)
        Dir.mkdir(directory, 0o700)
        registry.register(name, directory)
      end
      dns = Caramel::Latte::DNS.new(paths)
      dns.write(registry.list)
      File.read(dns.hosts_file).lines.sort.should eq(["127.0.0.1 bookshelf.caramel", "127.0.0.1 notes.caramel"])
      corefile = File.read(dns.config_file)
      corefile.should contain("bind 127.0.0.1")
      corefile.should contain("rcode REFUSED")
      # Readiness resolves every registered name, including .localhost sites.
      corefile.should contain("localhost:#{dns.port} {")
      corefile.should_not contain("forward")

      proxy = Caramel::Latte::Proxy.new(registry, https_port: 18443, http_port: 18080)
      config = JSON.parse(proxy.configuration)
      config["admin"]["listen"].as_s.should eq("unix/#{proxy.admin_socket}|0600")
      # Caddy provisions its default `local` CA for automated *.localhost
      # names; no CA it can use may install itself into trust stores.
      authorities = config["apps"]["pki"]["certificate_authorities"].as_h
      authorities.keys.sort.should eq(["caramel", "local"])
      authorities.values.map { |authority| authority["install_trust"]? }.should eq([false, false])
      server = config["apps"]["http"]["servers"]["https"]
      server["listen"].as_a.map(&.as_s).should eq(["127.0.0.1:18443"])
      server["strict_sni_host"].as_bool.should be_true
      routes = server["routes"].as_a
      routes.size.should eq(3)
      routes[0]["match"][0]["host"][0].as_s.should eq("bookshelf.caramel")
      routes[0]["handle"][0]["status_code"].as_i.should eq(503)
      routes.last["handle"][0]["status_code"].as_i.should eq(421)
      site = registry.list.find { |entry| entry.name == "bookshelf" }.not_nil!
      socket_path = File.join(paths.site_run_dir(site.id), "app.sock")
      listener = UNIXServer.new(socket_path)
      File.chmod(socket_path, 0o600)
      registry.set_upstream(site.id, socket_path)
      JSON.parse(proxy.configuration)["apps"]["http"]["servers"]["https"]["routes"][0]["handle"][0]["handler"].as_s.should eq("reverse_proxy")
      listener.close
      # Recreate a filesystem socket with no listener, as after a crashed app.
      stale = Socket.unix
      stale.bind(Socket::UNIXAddress.new(socket_path))
      File.chmod(socket_path, 0o600)
      stale.close
      JSON.parse(proxy.configuration)["apps"]["http"]["servers"]["https"]["routes"][0]["handle"][0]["status_code"].as_i.should eq(503)
      proxy.write
      File.info(proxy.config_file).permissions.value.should eq(0o600)
      registry.unregister(registry.list.first.id)
      JSON.parse(proxy.configuration)["apps"]["http"]["servers"]["https"]["routes"].as_a.size.should eq(2)
    ensure
      FileUtils.rm_rf(paths.run_dir) if paths
      FileUtils.rm_rf(root)
    end
  end
end
