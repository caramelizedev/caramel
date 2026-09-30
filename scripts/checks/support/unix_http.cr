require "./harness"
require "socket/unix_socket"

module Caramel::Checks::UnixHTTP
  MAX_BODY = 1024 * 1024

  def self.request(socket : String,
                   method : String,
                   path : String,
                   body : JSON::Any? = nil,
                   timeout : Time::Span = 15.seconds) : {Int32, JSON::Any?}
    connection = Socket.unix
    connection.connect(Socket::UNIXAddress.new(socket), timeout: timeout)
    connection.read_timeout = timeout
    connection.write_timeout = timeout
    client = HTTP::Client.new(connection, "latte")
    headers = HTTP::Headers{"Content-Type" => "application/json", "Connection" => "close"}
    client.exec(method, path, headers, body.try(&.to_json)) do |response|
      bytes = Bytes.new(MAX_BODY + 1)
      size = response.body_io.read_greedy(bytes)
      raise "Latte response exceeded 1 MiB" if size > MAX_BODY
      {response.status_code, size == 0 ? nil : JSON.parse(String.new(bytes[0, size]))}
    end
  ensure
    client.try &.close
    connection.try &.close
  end

  def self.json!(socket : String,
                 method : String,
                 path : String,
                 body : JSON::Any? = nil,
                 timeout : Time::Span = 15.seconds) : JSON::Any
    status, document = request(socket, method, path, body, timeout)
    raise "Latte request failed: #{status}" if status >= 400
    document || raise "Latte returned an empty response"
  end
end
