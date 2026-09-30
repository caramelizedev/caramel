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
      # Every zone is local-only. The .test system resolver is installed only
      # when explicitly chosen, never as a side effect of ordinary registration.
      # Readiness queries every registered name, so each suffix needs a zone.
      config = String.build do |io|
        Site::SUFFIXES.each do |suffix|
          zone = File.join(@paths.dns_dir, "#{suffix}.zone")
          ConfigFile.write(zone, zone_file(suffix))
          io << suffix_server(suffix, zone) << "\n"
        end
        io << refusing_server
      end
      ConfigFile.write(hosts_file, hosts(sites))
      ConfigFile.write(config_file, config)
    end

    private def zone_file(suffix : String) : String
      <<-ZONE
        $ORIGIN #{suffix}.
        $TTL 1
        @ IN SOA localhost. hostmaster.#{suffix}. (1 60 60 60 1)
          IN NS localhost.

        ZONE
    end

    # Answers a suffix's names from the hosts file, then from its zone.
    private def suffix_server(suffix : String, zone : String) : String
      <<-COREFILE
        #{suffix}:#{@port} {
            bind 127.0.0.1
            hosts #{hosts_file.to_json} {
                ttl 1
                reload 1s
                no_reverse
                fallthrough
            }
            file #{zone.to_json} #{suffix}
        }

        COREFILE
    end

    # Refuses every other name, so no query leaves this Mac.
    private def refusing_server : String
      <<-COREFILE
        .:#{@port} {
            bind 127.0.0.1
            template ANY ANY {
                rcode REFUSED
            }
        }

        COREFILE
    end

    private def hosts(sites : Array(Site)) : String
      sites.sort_by(&.domain).map { |site| "127.0.0.1 #{site.domain}\n" }.join
    end
  end
end
