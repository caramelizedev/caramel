require "./support/harness"

# Builds spec/fixtures/crema without the development flag and exercises its
# production logging: one JSON canonical line per request, request ids and
# `traceparent`, and an error line that never carries the exception message.

CURL = "/usr/bin/curl"

def request(socket : String, path : String, headers : Hash(String, String) = {} of String => String)
  argv = [CURL, "-s", "-i", "--unix-socket", socket, "-H", "Host: bookshelf.caramel"]
  headers.each { |name, value| argv.concat(["-H", "#{name}: #{value}"]) }
  result = Caramel::Checks.run(argv + ["http://crema#{path}"], timeout: 30.seconds)
  Caramel::Checks.fail(result.stdout + result.stderr) unless result.success?
  result.stdout
end

def json_lines(log : String) : Array(JSON::Any)
  lines = File.read(log).lines.select(&.starts_with?('{'))
  lines.map { |line| JSON.parse(line) }
end

def wait_for_line(log : String, message : String) : JSON::Any
  found = nil
  ready = Caramel::Checks.wait_until(10.seconds, 50.milliseconds) do
    found = json_lines(log).find { |line| line["msg"]? == message }
    !found.nil?
  end
  Caramel::Checks.fail("no #{message} line in #{File.read(log)}") unless ready
  found.not_nil!
end

root = Caramel::Checks.private_temp("caramel-crema-")
at_exit { FileUtils.rm_rf(root) }
binary = File.join(root, "crema")
build = Caramel::Checks.crystal(
  ["build", File.join(Caramel::Checks::REPO, "spec/fixtures/crema/main.cr"), "-o", binary],
  timeout: 1.hour)
Caramel::Checks.fail(build.stdout + build.stderr) unless build.success?

socket = File.join(root, "app.sock")
log = File.join(root, "stdout.log")
ops_socket = File.join(root, "ops.sock")
env = {
  "CARAMEL_ENV"          => "production",
  "CARAMEL_PROJECT_ROOT" => root,
  "CARAMEL_OPS_SOCKET"   => ops_socket,
}
process = File.open(log, "w") do |output|
  Process.new(binary, [socket], env: env, output: output, error: Process::Redirect::Inherit)
end
# Checks.fail exits, which skips ensure; at_exit still runs.
at_exit { Caramel::Checks.stop(process) }
ready = Caramel::Checks.wait_until(10.seconds, 50.milliseconds) do
  File.exists?(socket) && File.read(log).includes?("ready")
end
Caramel::Checks.fail("fixture did not start: #{File.read(log)}") unless ready

page = request(socket, "/books/1")
Caramel::Checks.fail(page) unless page.includes?("200")
line = wait_for_line(log, "request")
unless line["route"] == "/books/:id" && line["level"] == "info"
  Caramel::Checks.fail("unexpected request line: #{line}")
end
Caramel::Checks.fail("path leaked into #{line}") if line["path"]?
puts "PASS: production writes one JSON request line without the path"

echoed = request(socket, "/books/2", {"X-Request-ID" => "check-request-0001"})
Caramel::Checks.fail(echoed) unless echoed.downcase.includes?("x-request-id: check-request-0001")
logged = json_lines(log).any? { |entry| entry["request_id"]? == "check-request-0001" }
Caramel::Checks.fail("request id not logged") unless logged
puts "PASS: an inbound X-Request-ID is echoed and logged"

trace_id = "0af7651916cd43dd8448eb211c80319c"
parent = "b7ad6b7169203331"
request(socket, "/books/3", {"traceparent" => "00-#{trace_id}-#{parent}-01"})
continued = json_lines(log).any? do |entry|
  entry["trace_id"]? == trace_id && entry["parent_id"]? == parent
end
Caramel::Checks.fail("traceparent was not continued") unless continued
puts "PASS: an inbound traceparent continues"

request(socket, "/broken")
failure = wait_for_line(log, "error")
Caramel::Checks.fail("error line has no fingerprint: #{failure}") unless failure["fingerprint"]?
everything = File.read(log)
Caramel::Checks.fail("exception message reached stdout") if everything.includes?("do-not-log")
puts "PASS: an error line holds the fingerprint and not the message"

ops = ->(arguments : Array(String)) do
  result = Caramel::Checks.run([binary, "ops"] + arguments, env: env, timeout: 30.seconds)
  Caramel::Checks.fail(result.stdout + result.stderr) unless result.success?
  result.stdout
end
status = ops.call(["status"])
Caramel::Checks.fail("ops status has no App line") unless status.starts_with?("App ")
mode = File.info(ops_socket).permissions.value
Caramel::Checks.fail("ops socket is mode #{mode.to_s(8)}") unless mode == 0o600
puts "PASS: ops status answers on an owner-only socket"

fingerprint = failure["fingerprint"].as_s
listing = ops.call(["errors"])
Caramel::Checks.fail("ops errors lacks #{fingerprint}") unless listing.includes?(fingerprint)
detail = ops.call(["error", fingerprint])
message_shown = detail.includes?("do-not-log")
Caramel::Checks.fail("ops error lacks the message: #{detail}") unless message_shown
Caramel::Checks.fail("the message reached stdout") if File.read(log).includes?("do-not-log")
puts "PASS: the message is on the ops socket and never on stdout"

expected = %(caramel_requests_total{method="GET",route="/books/:id",status="200"})
metrics = ops.call(["metrics"])
Caramel::Checks.fail("ops metrics lacks #{expected}") unless metrics.includes?(expected)
puts "PASS: ops metrics counts requests by route and status"

rebinding = Caramel::Checks.run([CURL, "-s", "-o", "/dev/null", "-w", "%{http_code}",
                                 "--unix-socket", ops_socket, "-H", "Host: evil.example",
                                 "http://ops/v1/status"], timeout: 30.seconds)
Caramel::Checks.fail("evil Host got #{rebinding.stdout}") unless rebinding.stdout == "421"
puts "PASS: an unknown Host is refused with 421"

token = ops.call(["debug-token", "--minutes=5"]).lines.first.split.last
traced = request(socket, "/books/4", {"X-Caramel-Debug" => token})
header = traced.downcase.includes?("x-caramel-trace: ")
Caramel::Checks.fail("no X-Caramel-Trace in #{traced}") unless header
kept = ops.call(["traces", "--debug"]).includes?("debug")
Caramel::Checks.fail("ops traces --debug is empty") unless kept
puts "PASS: a debug token traces its request and the trace is kept"
