require "json"
require "socket"
require "./registry"
require "./config_file"

module Caramel::Latte
  # Whole-instance Caddy configuration. The caller supervises the process and
  # atomically loads this complete document through its private administration
  # socket, so registration retries cannot append duplicate routes.
  class Proxy
    getter https_port : Int32
    getter http_port : Int32

    def initialize(@registry : Registry, @https_port : Int32 = 443, @http_port : Int32 = 80, @public_https_port : Int32? = nil)
      unless (1..65535).includes?(@https_port) && (1..65535).includes?(@http_port) && @https_port != @http_port
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
      routes = sites.map do |site|
        handler = if socket = site.upstream
                    # Registry.list validates stored socket boundaries and
                    # permits missing entries after a stopped app. Connect
                    # directly so unlink during shutdown also becomes 503.
                    if listening?(socket)
                      JSON.parse({handler: "reverse_proxy", upstreams: [{dial: "unix/#{socket}"}],
                                  transport: {protocol: "http", dial_timeout: "2s", response_header_timeout: "30s"}}.to_json)
                    else
                      stopped_handler(site)
                    end
                  else
                    stopped_handler(site)
                  end
        JSON.parse({match: [{host: [site.domain]}], handle: [handler], terminal: true}.to_json)
      end
      routes << unknown_host
      redirects = sites.map do |site|
        public_port = @public_https_port || @https_port
        origin = public_port == 443 ? site.origin : "#{site.origin}:#{public_port}"
        JSON.parse({match: [{host: [site.domain]}], terminal: true,
                    handle: [{handler: "static_response", status_code: 308,
                              headers: {"Location" => ["#{origin}{http.request.uri}"]}}]}.to_json)
      end
      redirects << unknown_host
      {
        admin:   {listen: "unix/#{admin_socket}|0600", config: {persist: false}},
        storage: {module: "file_system", root: storage_dir},
        apps:    {
          pki:  {certificate_authorities: {caramel: {name: "Caramel Local Authority", install_trust: false}}},
          tls:  {certificates: {automate: domains}, automation: {policies: [{subjects: domains, issuers: [{module: "internal", ca: "caramel"}]}]}},
          http: {http_port: @http_port, https_port: @https_port, servers: {
            https: {listen: ["127.0.0.1:#{@https_port}"], strict_sni_host: true,
                    automatic_https: {disable_redirects: true, disable_certificates: true}, tls_connection_policies: [JSON.parse("{}")], routes: routes},
            http: {listen: ["127.0.0.1:#{@http_port}"], automatic_https: {disable: true}, routes: redirects},
          }},
        },
      }.to_json
    end

    def write : String
      ConfigFile.directory(@registry.paths.caddy_dir)
      ConfigFile.directory(storage_dir)
      environment.each_value { |path| ConfigFile.directory(path) }
      ConfigFile.write(config_file, configuration)
    end

    private def stopped_handler(site : Site) : JSON::Any
      JSON.parse({handler: "static_response", status_code: 503,
                  headers: {"Content-Type" => ["text/html; charset=utf-8"], "Cache-Control" => ["no-store"]},
                  body: "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>#{site.name} · Latte</title><main><h1>#{site.name} is taking a break</h1><p>Start this project with <code>frappe dev</code> to continue.</p></main></html>"}.to_json)
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
      JSON.parse({handle: [{handler: "static_response", status_code: 421, body: "Unknown Caramel project"}], terminal: true}.to_json)
    end
  end
end
