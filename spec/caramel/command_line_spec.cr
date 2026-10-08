require "spec"
require "socket"
require "../../src/caramel"

lib LibC
  fun dup(fd : Int) : Int
end

# What the block writes to STDERR.
private def stderr_of(& : ->) : String
  reader, writer = IO.pipe
  saved = IO::FileDescriptor.new(LibC.dup(STDERR.fd))
  STDERR.flush
  STDERR.reopen(writer)
  begin
    yield
    STDERR.flush
  ensure
    STDERR.reopen(saved)
    saved.close
    writer.close
  end
  reader.gets_to_end
end

private def with_environment(values : Hash(String, String?), &)
  saved = values.keys.to_h { |key| {key, ENV[key]?} }
  begin
    values.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
    yield
  ensure
    saved.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  end
end

private def run_with(url : String?) : {Int32, String, Bool}
  status = 0
  ran = false
  environment = {
    "CARAMEL_ENV"                   => "development",
    "CARAMEL_EXPECTED_DATABASE_URL" => nil,
    "DATABASE_URL"                  => url,
  } of String => String?
  printed = stderr_of do
    with_environment(environment) do
      status = Caramel::CommandLine.with_database(false) do |_, _|
        ran = true
        0
      end
    end
  end
  {status, printed, ran}
end

describe "Caramel::CommandLine.with_database" do
  it "reports a missing DATABASE_URL in one line and returns 1" do
    status, printed, ran = run_with(nil)
    status.should eq 1
    printed.should eq "Missing database configuration: DATABASE_URL\n"
    ran.should be_false
  end

  it "reports a refused connection in one line and returns 1" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    status, printed, ran = run_with("postgres://nobody@127.0.0.1:#{port}/x")
    status.should eq 1
    printed.lines.size.should eq 1
    printed.should start_with "Could not connect to the database: "
    printed.should contain "127.0.0.1:#{port}"
    ran.should be_false
  end

  it "reports an invalid database URL in one line and returns 1" do
    status, printed, ran = run_with("mysql://x@localhost/y")
    status.should eq 1
    printed.should eq "Invalid database configuration: " \
                      "database URL must use postgres:// or postgresql://\n"
    ran.should be_false
  end

  it "reports a database URL with an invalid port in one line and returns 1" do
    status, printed, ran = run_with("postgres://u:secret@localhost:abc/x")
    status.should eq 1
    printed.lines.size.should eq 1
    printed.should start_with "Invalid database configuration: "
    printed.should_not contain "secret"
    ran.should be_false
  end

  it "reports a database URL with an out-of-range port in one line and returns 1" do
    status, printed, ran = run_with("postgres://u:secret@localhost:99999999999/x")
    status.should eq 1
    printed.lines.size.should eq 1
    printed.should start_with "Invalid database configuration: "
    printed.should_not contain "secret"
    ran.should be_false
  end
end
