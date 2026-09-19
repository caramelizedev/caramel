require "json"
require "./paths"
require "./site"
require "./config_file"

module Caramel::Latte
  class DNS
    getter port : Int32

    def initialize(@paths : Paths, @port : Int32 = 15353)
      raise ArgumentError.new("invalid DNS port") unless (1024..65535).includes?(@port)
    end

    def config_file : String
      File.join(@paths.dns_dir, "Corefile")
    end

    def hosts_file : String
      File.join(@paths.dns_dir, "hosts")
    end

    def resolver_configuration : String
      "nameserver 127.0.0.1\nport #{@port}\n"
    end

    def write(sites : Array(Site)) : String
      ConfigFile.directory(@paths.dns_dir)
      # Both zones are local-only. The .test system resolver is installed only
      # when explicitly chosen, never as a side effect of ordinary registration.
      config = String.build do |io|
        %w(caramel test).each do |suffix|
          zone = File.join(@paths.dns_dir, "#{suffix}.zone")
          ConfigFile.write(zone, "$ORIGIN #{suffix}.\n$TTL 1\n@ IN SOA localhost. hostmaster.#{suffix}. (1 60 60 60 1)\n  IN NS localhost.\n")
          io << "#{suffix}:#{@port} {\n    bind 127.0.0.1\n"
          io << "    hosts #{hosts_file.to_json} {\n        ttl 1\n        reload 1s\n        no_reverse\n        fallthrough\n    }\n"
          io << "    file #{zone.to_json} #{suffix}\n}\n\n"
        end
        io << ".:#{@port} {\n    bind 127.0.0.1\n    template ANY ANY {\n        rcode REFUSED\n    }\n}\n"
      end
      ConfigFile.write(hosts_file, sites.sort_by(&.domain).map { |site| "127.0.0.1 #{site.domain}\n" }.join)
      ConfigFile.write(config_file, config)
    end
  end
end
