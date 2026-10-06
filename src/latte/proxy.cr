require "json"
require "socket"
require "./registry"
require "./config_file"

module Caramel::Latte
  # Whole-instance Caddy configuration. The caller supervises the process and
  # atomically loads this complete document through its private administration
  # socket, so registration retries cannot append duplicate routes.
  class Proxy
    ACCESS_LOG = "access.log"

    getter https_port : Int32
    getter http_port : Int32

    def initialize(@registry : Registry,
                   @https_port : Int32 = 443,
                   @http_port : Int32 = 80,
                   @public_https_port : Int32? = nil)
      unless valid_port?(@https_port) && valid_port?(@http_port) && @https_port != @http_port
        raise ArgumentError.new("invalid HTTP/HTTPS ports")
      end
    end

    def admin_socket : String
      File.join(@registry.paths.run_dir, "caddy.sock")
    end

    def config_file : String
      File.join(@registry.paths.caddy_dir, "caddy.json")
    end

    def storage_dir : String
      File.join(@registry.paths.caddy_dir, "storage")
    end

    def root_certificate : String
      File.join(storage_dir, "pki", "authorities", "caramel", "root.crt")
    end

    def environment : Hash(String, String)
      {"XDG_DATA_HOME"   => File.join(@registry.paths.caddy_dir, "data"),
       "XDG_CONFIG_HOME" => File.join(@registry.paths.caddy_dir, "config")}
    end

    def configuration : String
      sites = @registry.list.sort_by(&.domain)
      domains = sites.map(&.domain)
      routes = sites.map { |site| route(site) }
      routes << unknown_host
      redirects = sites.map { |site| redirect(site) }
      redirects << unknown_host
      {
        admin:   {listen: "unix/#{admin_socket}|0600", config: {persist: false}},
        logging: logging(sites),
        storage: {module: "file_system", root: storage_dir},
        apps:    {pki: pki_app, tls: tls_app(domains), http: http_app(routes, redirects, sites)},
      }.to_json
    end

    def write : String
      ConfigFile.directory(@registry.paths.caddy_dir)
      ConfigFile.directory(storage_dir)
      environment.each_value { |path| ConfigFile.directory(path) }
      @registry.list.each { |site| @registry.paths.site_log_dir(site.id) }
      ConfigFile.write(config_file, configuration)
    end

    private def valid_port?(port : Int32) : Bool
      (1..65535).includes?(port)
    end

    # Automating a name that cannot get a public certificate, such as
    # *.localhost, makes Caddy provision its default `local` CA for a hidden
    # internal policy; undeclared, that CA installs its root into the system,
    # Java and NSS trust stores. Every CA stays untrusted.
    private def pki_app
      caramel = {name: "Caramel Local Authority", install_trust: false}
      {certificate_authorities: {caramel: caramel, local: {install_trust: false}}}
    end

    private def tls_app(domains : Array(String))
      policy = {subjects: domains, issuers: [{module: "internal", ca: "caramel"}]}
      {certificates: {automate: domains}, automation: {policies: [policy]}}
    end

    # One access log per site, in the site's log directory, so a site's log is its own.
    # Caddy's roller keeps it to a megabyte and one previous file. The default logger
    # keeps writing everything else to stderr, which is `proxy.log`.
    private def logging(sites : Array(Site))
      logs = {"default" => JSON.parse(%({"exclude":["http.log.access"]}))}
      sites.each { |site| logs[logger_name(site)] = access_log(site) }
      {logs: logs}
    end

    private def access_log(site : Site) : JSON::Any
      filename = File.join(@registry.paths.logs_dir, "sites", site.id, ACCESS_LOG)
      writer = {
        output: "file", filename: filename, roll: true,
        roll_size_mb: 1, roll_keep: 1, mode: "0600",
      }
      log = {
        writer:  writer,
        encoder: {format: "json"},
        include: ["http.log.access.#{logger_name(site)}"],
      }
      JSON.parse(log.to_json)
    end

    private def logger_name(site : Site) : String
      "site_#{site.id}"
    end

    private def http_app(routes : Array(JSON::Any),
                         redirects : Array(JSON::Any),
                         sites : Array(Site))
      mapped = sites.to_h { |site| {site.domain, [logger_name(site)]} }
      https = {
        listen:                  ["127.0.0.1:#{@https_port}"],
        strict_sni_host:         true,
        automatic_https:         {disable_redirects: true, disable_certificates: true},
        tls_connection_policies: [JSON.parse("{}")],
        routes:                  routes,
        logs:                    {logger_names: mapped, skip_unmapped_hosts: true},
      }
      http = {
        listen:          ["127.0.0.1:#{@http_port}"],
        automatic_https: {disable: true},
        routes:          redirects,
      }
      {http_port: @http_port, https_port: @https_port, servers: {https: https, http: http}}
    end

    private def route(site : Site) : JSON::Any
      matcher = [{host: [site.domain]}]
      JSON.parse({match: matcher, handle: [handler(site)], terminal: true}.to_json)
    end

    # Sends a site's plain-HTTP requests to its HTTPS origin.
    private def redirect(site : Site) : JSON::Any
      public_port = @public_https_port || @https_port
      origin = public_port == 443 ? site.origin : "#{site.origin}:#{public_port}"
      location = {"Location" => ["#{origin}{http.request.uri}"]}
      handler = {handler: "static_response", status_code: 308, headers: location}
      matcher = [{host: [site.domain]}]
      JSON.parse({match: matcher, terminal: true, handle: [handler]}.to_json)
    end

    # Registry.list validates stored socket boundaries and permits missing
    # entries after a stopped app. Connect directly so unlink during shutdown
    # also becomes 503.
    private def handler(site : Site) : JSON::Any
      socket = site.upstream
      return stopped_handler(site) unless socket && listening?(socket)
      proxy_handler(socket)
    end

    private def proxy_handler(socket : String) : JSON::Any
      handler = {
        handler:   "reverse_proxy",
        upstreams: [{dial: "unix/#{socket}"}],
        transport: {protocol: "http", dial_timeout: "2s", response_header_timeout: "30s"},
      }
      JSON.parse(handler.to_json)
    end

    private def stopped_handler(site : Site) : JSON::Any
      headers = {
        "Content-Type"  => ["text/html; charset=utf-8"],
        "Cache-Control" => ["no-store"],
      }
      handler = {
        handler:     "static_response",
        status_code: 503,
        headers:     headers,
        body:        break_page(site),
      }
      JSON.parse(handler.to_json)
    end

    # The page a stopped project shows in place of the application.
    private def break_page(site : Site) : String
      "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\">" \
      "<meta name=\"viewport\" content=\"width=device-width\">" \
      "<title>#{site.name} · Latte</title>" \
      "<main><h1>#{site.name} is taking a break</h1>" \
      "<p>Start this project with <code>frappe dev</code> to continue.</p></main></html>"
    end

    private def listening?(path : String) : Bool
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(path), timeout: 100.milliseconds)
      true
    rescue IO::Error
      false
    ensure
      socket.try(&.close)
    end

    private def unknown_host : JSON::Any
      handler = {handler: "static_response", status_code: 421, body: "Unknown Caramel project"}
      JSON.parse({handle: [handler], terminal: true}.to_json)
    end
  end
end
