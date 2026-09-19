require "spec"
require "socket"
require "../../src/caramel/database"

describe "PostgreSQL TLS negotiation" do
  ["N", "X", ""].each do |reply|
    it "fails closed before startup when the server replies #{reply.inspect}" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      observed = Channel({Bytes, UInt8?}).new(1)
      spawn do
        peer = server.accept
        begin
          peer.read_timeout = 2.seconds
          request = Bytes.new(8)
          peer.read_fully(request)
          peer.write(reply.to_slice)
          peer.flush
          if reply.empty?
            peer.close
            observed.send({request, nil})
          else
            observed.send({request, peer.read_byte})
          end
        ensure
          peer.close unless peer.closed?
        end
      end
      begin
        expect_raises(IO::Error, "PostgreSQL server did not accept TLS") do
          Caramel::Database.open("postgresql://test:must-not-be-sent@127.0.0.1:#{port}/test")
        end
        request, next_byte = observed.receive
        request.should eq(Bytes[0, 0, 0, 8, 4, 210, 22, 47])
        next_byte.should be_nil
      ensure
        server.close
      end
    end
  end
end
