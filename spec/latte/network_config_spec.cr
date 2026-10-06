require "spec"
require "file_utils"
require "socket"
require "../../src/latte/dns"
require "../../src/latte/proxy"

# The HTTPS server's routes in *proxy*'s configuration now.
private def https_routes(proxy : Caramel::Latte::Proxy) : Array(JSON::Any)
  JSON.parse(proxy.configuration)["apps"]["http"]["servers"]["https"]["routes"].as_a
end

describe "Latte network configuration" do
  it "registers exact hosts and produces isolated local HTTPS configuration" do
    root = File.join("/private/tmp", "latte-network-config-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    # ameba:disable Lint/UselessAssign -- read by the ensure below
    paths = nil
    begin
      registry = Caramel::Latte::Registry.new(root)
      paths = registry.paths
      %w[bookshelf notes].each do |name|
        directory = File.join(root, name)
        Dir.mkdir(directory, 0o700)
        registry.register(name, directory)
      end
      dns = Caramel::Latte::DNS.new(paths)
      dns.write(registry.list)
      hosts = ["127.0.0.1 bookshelf.caramel", "127.0.0.1 notes.caramel"]
      File.read(dns.hosts_file).lines.sort!.should eq(hosts)
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
      authorities.keys.sort!.should eq(["caramel", "local"])
      authorities.values.map { |authority| authority["install_trust"]? }.should eq([false, false])
      server = config["apps"]["http"]["servers"]["https"]
      server["listen"].as_a.map(&.as_s).should eq(["127.0.0.1:18443"])
      server["strict_sni_host"].as_bool.should be_true
      routes = server["routes"].as_a
      routes.size.should eq(3)
      routes[0]["match"][0]["host"][0].as_s.should eq("bookshelf.caramel")
      routes[0]["handle"][0]["status_code"].as_i.should eq(503)
      routes.last["handle"][0]["status_code"].as_i.should eq(421)
      bookshelf = registry.list.find! { |entry| entry.name == "bookshelf" }
      notes = registry.list.find! { |entry| entry.name == "notes" }
      logs = config["logging"]["logs"].as_h
      logs.keys.sort!.should eq(["default", "site_#{bookshelf.id}", "site_#{notes.id}"].sort)
      logs["default"]["exclude"].as_a.map(&.as_s).should eq(["http.log.access"])
      access = logs["site_#{bookshelf.id}"]
      writer = access["writer"]
      expected = File.join(paths.logs_dir, "sites", bookshelf.id, "access.log")
      writer["filename"].as_s.should eq(expected)
      {writer["roll"].as_bool, writer["roll_size_mb"].as_i, writer["mode"].as_s}
        .should eq({true, 1, "0600"})
      access["include"].as_a.map(&.as_s).should eq(["http.log.access.site_#{bookshelf.id}"])
      access["encoder"]["format"].as_s.should eq("json")
      server["logs"]["skip_unmapped_hosts"].as_bool.should be_true
      mapped = server["logs"]["logger_names"].as_h
      mapped["bookshelf.caramel"].as_a.map(&.as_s).should eq(["site_#{bookshelf.id}"])
      mapped["notes.caramel"].as_a.map(&.as_s).should eq(["site_#{notes.id}"])
      site = registry.list.find! { |entry| entry.name == "bookshelf" }
      socket_path = File.join(paths.site_run_dir(site.id), "app.sock")
      listener = UNIXServer.new(socket_path)
      File.chmod(socket_path, 0o600)
      registry.set_upstream(site.id, socket_path)
      https_routes(proxy)[0]["handle"][0]["handler"].as_s.should eq("reverse_proxy")
      listener.close
      # Recreate a filesystem socket with no listener, as after a crashed app.
      stale = Socket.unix
      stale.bind(Socket::UNIXAddress.new(socket_path))
      File.chmod(socket_path, 0o600)
      stale.close
      https_routes(proxy)[0]["handle"][0]["status_code"].as_i.should eq(503)
      proxy.write
      File.info(proxy.config_file).permissions.value.should eq(0o600)
      File.info(File.dirname(writer["filename"].as_s)).permissions.value.should eq(0o700)
      registry.unregister(registry.list.first.id)
      https_routes(proxy).size.should eq(2)
    ensure
      FileUtils.rm_rf(paths.run_dir) if paths
      FileUtils.rm_rf(root)
    end
  end

  it "writes the same configuration whatever order sites were registered in" do
    root = File.join("/private/tmp", "latte-network-order-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    begin
      registry = Caramel::Latte::Registry.new(root)
      %w[bookshelf notes].each { |name| Dir.mkdir(File.join(root, name), 0o700) }
      proxy = Caramel::Latte::Proxy.new(registry, https_port: 18443, http_port: 18080)
      %w[bookshelf notes].each { |name| registry.register(name, File.join(root, name)) }
      forward = proxy.configuration
      %w[bookshelf notes].each { |name| registry.unregister(name) }
      %w[notes bookshelf].each { |name| registry.register(name, File.join(root, name)) }
      proxy.configuration.should eq(forward)
      File.exists?(File.join(root, "logs", "sites")).should be_false
    ensure
      FileUtils.rm_rf(registry.paths.run_dir) if registry
      FileUtils.rm_rf(root)
    end
  end
end
