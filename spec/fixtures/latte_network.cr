require "../../src/latte/dns"
require "../../src/latte/proxy"

# A command-line fixture for exercising the actual generated service configs.
# It never launches services or changes system resolver/certificate trust.
root, mode = ARGV[0], ARGV[1]
registry = Caramel::Latte::Registry.new(root)
paths = registry.paths
dns = Caramel::Latte::DNS.new(paths, ARGV[2].to_i)
proxy = Caramel::Latte::Proxy.new(registry, https_port: ARGV[3].to_i, http_port: ARGV[4].to_i)
case mode
when "prepare"
  %w(bookshelf notes).each do |name|
    directory = File.join(root, name)
    Dir.mkdir(directory, 0o700)
    registry.register(name, directory)
  end
when "route"
  registry.list.each do |site|
    registry.set_upstream(site.id, File.join(paths.site_run_dir(site.id), "app.sock"))
  end
when "unregister"
  site = registry.list.find { |item| item.name == "notes" }.not_nil!
  registry.unregister(site.id)
else
  raise "unknown fixture mode"
end
dns.write(registry.list)
proxy.write
puts({corefile: dns.config_file, caddy_config: proxy.config_file, admin: proxy.admin_socket,
      ca: proxy.root_certificate, environment: proxy.environment, runtime: paths.run_dir,
      sites: registry.list.map { |site| {name: site.name, domain: site.domain,
                                         socket: File.join(paths.site_run_dir(site.id), "app.sock")} }}.to_json)
