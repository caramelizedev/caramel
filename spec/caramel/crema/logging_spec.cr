require "spec"
require "../../../src/caramel/crema"

private def entry_at(message : String,
                     data,
                     source : String = "crema",
                     severity : Log::Severity = Log::Severity::Info) : Log::Entry
  stamp = Time.local(2026, 10, 3, 12, 0, 0, nanosecond: 123_000_000)
  Log::Entry.new(source, severity, message, Log::Metadata.build(data), nil, timestamp: stamp)
end

describe Caramel::Crema::TextFormat do
  it "renders a request line" do
    entry = entry_at("request", {
      method: "GET", route: "/books/:id", path: "/books/1", status: 200, duration_ms: 12.4,
      db_count: 3, db_ms: 4.1, view_ms: 2.0, action: "App::Books::Show", request_id: "8b1f",
    })
    expected = "12:00:00.123 INFO   request GET /books/1 200 12.4ms db=3/4.1ms " \
               "view=2.0ms App::Books::Show request_id=8b1f"
    Caramel::Crema::TextFormat.line(entry).should eq(expected)
  end

  it "falls back to the route, then a dash, and appends flags in order" do
    entry = entry_at("request", {
      method: "GET", status: 500, duration_ms: 1.0, db_count: 0, db_ms: 0.0, view_ms: 0.0,
      repeated_queries: 2, slow_queries: 1, error_class: "KeyError", debug: true,
    })
    expected = "12:00:00.123 INFO   request GET - 500 1.0ms db=0/0.0ms view=0.0ms " \
               "repeated=2 slow_queries=1 error=KeyError debug"
    Caramel::Crema::TextFormat.line(entry).should eq(expected)
  end

  it "renders a job line" do
    entry = entry_at("job", {
      name: "App::SendInvitation", job_id: 42_i64, outcome: "ok", duration_ms: 31.0,
      db_count: 2, db_ms: 1.2, queue: "default", attempt: 1, queue_lag_ms: 12.0,
      request_id: "8b1f",
    })
    expected = "12:00:00.123 INFO   job App::SendInvitation #42 ok 31.0ms db=2/1.2ms " \
               "queue=default attempt=1 lag=12.0ms request_id=8b1f"
    Caramel::Crema::TextFormat.line(entry).should eq(expected)
  end

  it "renders a schedule line" do
    entry = entry_at("schedule", {
      name: "nightly_digest", outcome: "ok", duration_ms: 120.0, db_count: 4, db_ms: 9.9,
    })
    expected = "12:00:00.123 INFO   schedule nightly_digest ok 120.0ms db=4/9.9ms"
    Caramel::Crema::TextFormat.line(entry).should eq(expected)
  end

  it "renders an error line, quoting a value with a space" do
    entry = entry_at("error", {
      error_class: "KeyError", fingerprint: "9f2c4e1a7b3d", location: "app/a.cr:12:7",
      source: "GET /books/:id", request_id: "8b1f",
    }, severity: Log::Severity::Error)
    expected = "12:00:00.123 ERROR  error KeyError fingerprint=9f2c4e1a7b3d at app/a.cr:12:7 " \
               "source=\"GET /books/:id\" request_id=8b1f"
    Caramel::Crema::TextFormat.line(entry).should eq(expected)
  end

  it "renders any other entry as source: message and data" do
    entry = entry_at("LISTEN connection lost; reconnecting", {request_id: "8b1f"},
      source: "cold_brew.pubsub", severity: Log::Severity::Warn)
    expected = "12:00:00.123 WARN   cold_brew.pubsub: LISTEN connection lost; reconnecting " \
               "request_id=8b1f"
    Caramel::Crema::TextFormat.line(entry).should eq(expected)
  end
end

describe Caramel::Crema::JsonFormat do
  it "writes ts, level, source and msg, then the flattened data" do
    entry = entry_at("request", {route: "/books/:id", status: 200})
    json = JSON.parse(Caramel::Crema::JsonFormat.line(entry))
    json["level"].should eq("info")
    json["source"].should eq("crema")
    json["msg"].should eq("request")
    json["route"].should eq("/books/:id")
    json["status"].should eq(200)
    json["ts"].as_s.should end_with("Z")
  end

  it "writes an error's source beside the log source, not over it" do
    entry = entry_at("error", {error_class: "KeyError", source: "GET /books/:id"})
    json = JSON.parse(Caramel::Crema::JsonFormat.line(entry))
    json["source"].should eq("crema")
    json["data_source"].should eq("GET /books/:id")
  end
end

describe Caramel::Crema::Logging do
  it "drops below LOG_LEVEL and defaults to info" do
    Caramel::Crema::Logging.level({"LOG_LEVEL" => "warn"}).should eq(Log::Severity::Warn)
    Caramel::Crema::Logging.level({} of String => String).should eq(Log::Severity::Info)
  end

  it "uses JSON outside development and test, and lets CARAMEL_LOG_FORMAT win" do
    Caramel::Crema::Logging.json?({} of String => String).should be_true
    Caramel::Crema::Logging.json?({"CARAMEL_ENV" => "development"}).should be_false
    Caramel::Crema::Logging.json?({"CARAMEL_ENV" => "test"}).should be_false
    forced = {"CARAMEL_ENV" => "development", "CARAMEL_LOG_FORMAT" => "json"}
    Caramel::Crema::Logging.json?(forced).should be_true
  end
end
