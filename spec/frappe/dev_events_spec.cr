require "spec"
require "file_utils"
require "./support/events"
require "../../src/frappe/dev_events"

private def event_directories : {String, String}
  root = "/private/tmp/caramel-events-#{Random::Secure.hex(6)}"
  Dir.mkdir(root, 0o700)
  logs = File.join(root, "logs")
  Dir.mkdir(logs, 0o700)
  {root, logs}
end

private def eventually(& : -> Bool) : Nil
  deadline = Time.instant + 3.seconds
  until yield
    fail "timed out" if Time.instant > deadline
    sleep 10.milliseconds
  end
end

describe Caramel::Frappe::DevEvents do
  it "keeps the traces an application sends, skips garbage and survives a restart" do
    root, logs = event_directories
    events = Caramel::Frappe::DevEvents.new(root, logs, IO::Memory.new)
    events.start
    begin
      ok = EventFixtures.trace("GET /", "1" * 32)
      failing = EventFixtures.trace("GET /books/:id", "2" * 32, failing: true)
      UNIXSocket.open(events.socket) do |client|
        client << EventFixtures.line(ok) << "\n" << "not json\n"
        client << EventFixtures.line(failing) << "\n"
      end
      eventually { events.latest == 2 }
      events.traces.map(&.[1].name).should eq(["GET /books/:id", "GET /"])
      events.find("last-error").not_nil!.trace_id.should eq("2" * 32)
      events.find("last").not_nil!.trace_id.should eq("2" * 32)
      events.find("111111").not_nil!.name.should eq("GET /")
    ensure
      events.close
    end
    again = Caramel::Frappe::DevEvents.new(root, logs, IO::Memory.new)
    again.latest.should eq(2)
    again.find("last-error").not_nil!.error.not_nil!.fingerprint.should eq("9f2c4e1a7b3d")
    again.close
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "skips a line over a megabyte and keeps reading the connection" do
    root, logs = event_directories
    events = Caramel::Frappe::DevEvents.new(root, logs, IO::Memory.new)
    events.start
    begin
      UNIXSocket.open(events.socket) do |client|
        client << "x" * (Caramel::Frappe::DevEvents::MAX_LINE + 10) << "\n"
        client << EventFixtures.line(EventFixtures.trace) << "\n"
      end
      eventually { events.latest == 1 }
    ensure
      events.close
    end
  ensure
    FileUtils.rm_rf(root) if root
  end
end
