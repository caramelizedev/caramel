require "socket"

module Caramel
  module Outbound
    # Every address `direct` connects to is public: not loopback, private, link-local,
    # multicast or reserved, decided on the bytes so that no spelling of a host (decimal,
    # hex, v4-mapped IPv6) reaches a network the application did not mean to call.
    def self.public_address?(ip : Socket::IPAddress) : Bool
      address_class(ip).nil?
    end

    # The class of an address `direct` refuses, or nil when it is public: "loopback",
    # "private" (RFC 1918, shared address space and unique local), "link-local",
    # "multicast" or "reserved" (unspecified, documentation, benchmarking, 240/4 and
    # broadcast). A v4-mapped or NAT64 address is classified by its embedded IPv4.
    def self.address_class(ip : Socket::IPAddress) : String?
      case ip.family
      when .inet?  then v4_class(v4_bytes(ip))
      when .inet6? then v6_class(v6_bytes(ip))
      else              "reserved"
      end
    end

    private def self.v4_bytes(ip : Socket::IPAddress) : UInt8[4]
      ip.to_unsafe.as(LibC::SockaddrIn*).value.sin_addr.unsafe_as(StaticArray(UInt8, 4))
    end

    private def self.v6_bytes(ip : Socket::IPAddress) : UInt8[16]
      ip.to_unsafe.as(LibC::SockaddrIn6*).value.sin6_addr.unsafe_as(StaticArray(UInt8, 16))
    end

    private def self.v4_class(bytes : UInt8[4]) : String?
      first, second, third = bytes[0], bytes[1], bytes[2]
      return "loopback" if first == 127
      return "private" if v4_private?(first, second)
      return "link-local" if first == 169 && second == 254
      return "multicast" if 224 <= first < 240
      return "reserved" if v4_reserved?(first, second, third)

      nil
    end

    # 10/8, 172.16/12, 192.168/16 (RFC 1918) and the shared address space 100.64/10.
    private def self.v4_private?(first : UInt8, second : UInt8) : Bool
      return true if first == 10 || (first == 172 && (second & 0xf0) == 16)

      (first == 192 && second == 168) || (first == 100 && (second & 0xc0) == 64)
    end

    # 0/8, 240/4 with broadcast, 192.0.0/24, benchmarking 198.18/15 and documentation.
    private def self.v4_reserved?(first : UInt8, second : UInt8, third : UInt8) : Bool
      return true if first == 0 || first >= 240
      return true if first == 192 && second == 0 && third == 0
      return true if first == 198 && (second & 0xfe) == 18

      v4_documentation?(first, second, third)
    end

    # 192.0.2/24, 198.51.100/24 and 203.0.113/24 (RFC 5737).
    private def self.v4_documentation?(first : UInt8, second : UInt8, third : UInt8) : Bool
      return true if first == 192 && second == 0 && third == 2
      return true if first == 198 && second == 51 && third == 100

      first == 203 && second == 0 && third == 113
    end

    private def self.v6_class(bytes : UInt8[16]) : String?
      if embedded_v4?(bytes)
        return v4_class(UInt8.static_array(bytes[12], bytes[13], bytes[14], bytes[15]))
      end
      if bytes.to_slice[0, 15].all?(&.zero?)
        return "loopback" if bytes[15] == 1
        return "reserved" if bytes[15] == 0
      end
      return "private" if (bytes[0] & 0xfe) == 0xfc
      return "link-local" if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
      return "multicast" if bytes[0] == 0xff
      return "reserved" if v6_documentation?(bytes)

      nil
    end

    # `::ffff:a.b.c.d` (v4-mapped) or `64:ff9b::a.b.c.d` (NAT64, RFC 6052).
    private def self.embedded_v4?(bytes : UInt8[16]) : Bool
      return true if bytes.to_slice[0, 10].all?(&.zero?) && bytes[10] == 0xff && bytes[11] == 0xff

      bytes[0] == 0 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b &&
        bytes.to_slice[4, 8].all?(&.zero?)
    end

    # 2001:db8::/32 (RFC 3849).
    private def self.v6_documentation?(bytes : UInt8[16]) : Bool
      bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8
    end
  end
end
