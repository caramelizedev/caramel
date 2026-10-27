require "spec"
require "http/server"
require "../../src/caramel/outbound"

private def ip(address : String) : Socket::IPAddress
  Socket::IPAddress.new(address, 0)
end

# A server on 127.0.0.1 answering with *handler*, yielding its base URL with the
# Outbound settings restored afterwards.
private def serving(handler : HTTP::Server::Context ->, &)
  server = HTTP::Server.new(handler)
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  previous = {Caramel::Outbound.proxy, Caramel::Outbound.allow_private?,
              Caramel::Outbound.deadline, Caramel::Outbound.max_response_bytes}
  Caramel::Outbound.proxy = nil
  begin
    yield "http://127.0.0.1:#{address.port}"
  ensure
    Caramel::Outbound.proxy = previous[0]
    Caramel::Outbound.allow_private = previous[1]
    Caramel::Outbound.deadline = previous[2]
    Caramel::Outbound.max_response_bytes = previous[3]
    server.close
  end
end

describe Caramel::Outbound do
  describe ".public_address?" do
    it "refuses loopback, private, link-local, multicast and reserved ranges" do
      refused = [
        "0.0.0.0", "0.1.2.3", "10.1.2.3", "100.64.0.1", "100.127.255.255", "127.0.0.1",
        "127.255.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.0.0.1",
        "192.0.2.1", "192.168.1.1", "198.18.0.1", "198.19.255.255", "198.51.100.7",
        "203.0.113.9", "224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.255",
        "::", "::1", "fc00::1", "fdff::1", "fe80::1", "febf::1", "ff02::1", "2001:db8::1",
        "::ffff:10.0.0.1", "::ffff:127.0.0.1", "::ffff:169.254.169.254", "64:ff9b::a00:1",
      ]
      refused.each do |address|
        Caramel::Outbound.public_address?(ip(address)).should be_false, address
      end
    end

    it "accepts the addresses on either side of those ranges" do
      accepted = [
        "1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.0", "172.15.255.255",
        "172.32.0.0", "192.0.1.1", "192.0.3.1", "198.17.255.255", "198.20.0.0",
        "223.255.255.255", "2606:4700::1111", "2001:db9::1", "::ffff:8.8.8.8",
        "64:ff9b::808:808", "fbff::1", "fec0::1",
      ]
      accepted.each do |address|
        Caramel::Outbound.public_address?(ip(address)).should be_true, address
      end
    end

    it "names the class of a refused address" do
      classes = {
        "127.0.0.1"        => "loopback",
        "10.0.0.1"         => "private",
        "100.64.0.1"       => "private",
        "fd00::1"          => "private",
        "169.254.169.254"  => "link-local",
        "fe80::1"          => "link-local",
        "224.0.0.1"        => "multicast",
        "ff02::1"          => "multicast",
        "192.0.2.1"        => "reserved",
        "::"               => "reserved",
        "::ffff:127.0.0.1" => "loopback",
        "8.8.8.8"          => nil,
      }
      classes.each do |address, kind|
        Caramel::Outbound.address_class(ip(address)).should eq(kind), address
      end
    end

    it "sees through decimal and hex host spellings once Addrinfo resolves them" do
      ["2130706433", "0x7f000001", "127.1"].each do |spelling|
        resolved = Socket::Addrinfo.tcp(spelling, 80).map(&.ip_address)
        resolved.should_not be_empty, spelling
        resolved.each do |address|
          Caramel::Outbound.address_class(address).should eq("loopback"), spelling
        end
      end
    end
  end

  describe ".get" do
    it "refuses a loopback host unless allow_private is set" do
      reached = ->(context : HTTP::Server::Context) { context.response.print("reached") }
      serving(reached) do |base|
        error = expect_raises(Caramel::Outbound::Blocked) do
          Caramel::Outbound.get("#{base}/secret?token=1")
        end
        error.message.should eq("Outbound refuses 127.0.0.1: it resolves to a loopback address")
        Caramel::Outbound.allow_private = true
        Caramel::Outbound.get("#{base}/secret?token=1").body.should eq("reached")
      end
    end

    it "raises TooLarge once the body passes max_response_bytes" do
      cap = 1024
      large = ->(context : HTTP::Server::Context) { context.response.print("x" * (cap * 4)) }
      serving(large) do |base|
        Caramel::Outbound.allow_private = true
        Caramel::Outbound.max_response_bytes = cap
        expect_raises(Caramel::Outbound::TooLarge, "exceeds 1024 bytes") do
          Caramel::Outbound.get("#{base}/large")
        end
        Caramel::Outbound.max_response_bytes = cap * 4
        Caramel::Outbound.get("#{base}/large").body.bytesize.should eq(cap * 4)
      end
    end

    it "times out when the server stalls past the deadline" do
      released = Channel(Nil).new
      stalled = ->(context : HTTP::Server::Context) do
        released.receive
        context.response.print("late")
      end
      serving(stalled) do |base|
        Caramel::Outbound.allow_private = true
        Caramel::Outbound.deadline = 0.2.seconds
        started = Time.instant
        expect_raises(IO::TimeoutError, "did not finish within 0.2 seconds") do
          Caramel::Outbound.get("#{base}/slow")
        end
        (Time.instant - started).should be < 5.seconds
        released.send(nil)
      end
    end
  end
end
