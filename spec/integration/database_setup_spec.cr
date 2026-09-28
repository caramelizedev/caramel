require "spec"
require "random/secure"
require "socket"
require "uri"
require "../../src/caramel/database"

private SETUP_PORT = 55_437

private def setup_spec_socket_directory : String
  path = File.join("/private/tmp", "caramel-setup-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir(path, 0o700)
  path
end

private def read_backend_message(socket : UNIXSocket) : UInt8
  type = socket.read_byte
  raise "fake PostgreSQL peer reached EOF" unless type

  length = socket.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
  raise "invalid PostgreSQL message length" if length < 4

  body = Bytes.new(length - 4)
  socket.read_fully(body) unless body.empty?
  type
end

private def write_backend_message(socket : UNIXSocket, type : UInt8, body : Bytes = Bytes.empty) : Nil
  socket.write_byte(type)
  socket.write_bytes((body.size + 4).to_i32, IO::ByteFormat::NetworkEndian)
  socket.write(body) unless body.empty?
  socket.flush
end

private def fake_authentication_ok(socket : UNIXSocket) : Nil
  write_backend_message(socket, 'R'.ord.to_u8, Bytes[0, 0, 0, 0])
  write_backend_message(socket, 'Z'.ord.to_u8, Bytes['I'.ord.to_u8])
end

private def fake_startup(socket : UNIXSocket) : Nil
  length = socket.read_bytes(Int32, IO::ByteFormat::NetworkEndian)
  raise "invalid PostgreSQL startup packet" if length < 8

  payload = Bytes.new(length - 4)
  socket.read_fully(payload) unless payload.empty?
  fake_authentication_ok(socket)
end

private def fake_setup_query(socket : UNIXSocket) : Nil
  5.times { read_backend_message(socket) }
end

private def fake_setup_success(socket : UNIXSocket) : Nil
  fake_setup_query(socket)
  write_backend_message(socket, '1'.ord.to_u8)
  write_backend_message(socket, '2'.ord.to_u8)
  write_backend_message(socket, 'n'.ord.to_u8)
  write_backend_message(socket, 'C'.ord.to_u8, "SET\0".to_slice)
  write_backend_message(socket, 'Z'.ord.to_u8, Bytes['I'.ord.to_u8])
end

private def fake_setup_failure(socket : UNIXSocket) : Nil
  fake_setup_query(socket)
  write_backend_message(socket, '1'.ord.to_u8)
  write_backend_message(socket, '2'.ord.to_u8)
  error = "SERROR\0CXX000\0MUTC setup failed\0\0".to_slice
  write_backend_message(socket, 'E'.ord.to_u8, error)
  write_backend_message(socket, 'Z'.ord.to_u8, Bytes['E'.ord.to_u8])
end

private def wait_for_client_close(socket : UNIXSocket) : Bool
  loop do
    return true unless socket.read_byte
  end
rescue IO::TimeoutError
  false
end

describe "Caramel database session setup" do
  it "closes a future connection when UTC setup fails" do
    directory = setup_spec_socket_directory
    socket_path = File.join(directory, ".s.PGSQL.#{SETUP_PORT}")
    server = UNIXServer.new(socket_path)
    server_status = Channel(String).new(1)

    spawn do
      first_peer = server.accept
      begin
        first_peer.read_timeout = 2.seconds
        fake_startup(first_peer)
        fake_setup_success(first_peer)
      ensure
        first_peer.close unless first_peer.closed?
      end

      second_peer = server.accept
      begin
        second_peer.read_timeout = 2.seconds
        fake_startup(second_peer)
        fake_setup_failure(second_peer)
        server_status.send(wait_for_client_close(second_peer) ? "closed" : "timeout")
      rescue ex
        server_status.send("error: #{ex.class}: #{ex.message}")
      ensure
        second_peer.close unless second_peer.closed?
      end
    rescue ex
      server_status.send("error: #{ex.class}: #{ex.message}")
    end

    database = nil
    # ameba:disable Lint/UselessAssign
    first_connection = nil
    begin
      url = "postgresql://caramel:@/books?host=#{URI.encode_path(directory)}&port=#{SETUP_PORT}"
      database = Caramel::Database.open(url, pool_size: 2)
      first_connection = database.checkout

      setup_error = expect_raises(PQ::PQError) do
        database.checkout
      end
      setup_error.message.not_nil!.should contain("UTC setup failed")

      status = select
      when value = server_status.receive
        value
      when timeout(3.seconds)
        "timeout waiting for fake peer"
      end
      status.should eq("closed")
    ensure
      begin
        first_connection.try(&.release)
      rescue
      end
      begin
        database.try(&.close)
      rescue
      end
      begin
        server.close
      rescue
      end
      begin
        Dir.delete(directory) if Dir.exists?(directory)
      rescue
      end
    end
  end
end
