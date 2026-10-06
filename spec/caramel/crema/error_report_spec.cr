require "spec"
require "../../../src/caramel/crema"

private def failing_twice(first : Bool) : Exception
  raise KeyError.new("one") if first
  raise KeyError.new("two")
rescue error
  error
end

private def failing_elsewhere : Exception
  raise KeyError.new("three")
rescue error
  error
end

private def report_of(error : Exception) : Caramel::Crema::ErrorReport
  Caramel::Crema::ErrorReport.build(error, handled: false, source: nil)
end

describe Caramel::Crema::ErrorReport do
  it "groups errors of one class raised from one method, whatever the line" do
    first = report_of(failing_twice(true))
    second = report_of(failing_twice(false))
    first.fingerprint.should eq(second.fingerprint)
    first.fingerprint.should match(/\A[0-9a-f]{12}\z/)
  end

  it "separates the same class raised from two methods" do
    report_of(failing_twice(true)).fingerprint
      .should_not eq(report_of(failing_elsewhere).fingerprint)
  end

  it "locates the failure with a line and column" do
    report_of(failing_elsewhere).location.to_s.should match(/error_report_spec\.cr:\d+:\d+\z/)
  end

  it "makes an application path relative to the project and keeps others whole" do
    Caramel::Crema::Frames.relative("/proj/app/a.cr", "/proj").should eq("app/a.cr")
    outside = "/usr/lib/crystal/a.cr"
    Caramel::Crema::Frames.relative(outside, "/proj").should eq(outside)
  end

  it "redacts credential assignments from the message" do
    report = report_of(KeyError.new("connect failed password=hunter2"))
    report.message.should_not contain("hunter2")
    report.message.should contain("[credential redacted]")
  end

  it "redacts secret-looking environment values and database URLs" do
    env = {"APP_API_KEY" => "s3cret-value-123", "DATABASE_URL" => "postgres://u:pw9@db/app"}
    secrets = Caramel::Crema::Redact.secrets(env)
    text = "key s3cret-value-123 pw9 postgres://u:pw9@db/app"
    redacted = Caramel::Crema::Redact.text(text, secrets, 1000)
    redacted.should_not contain("s3cret-value-123")
    redacted.should_not contain("pw9")
  end

  it "keeps a secret whose value is not a valid URL instead of raising" do
    env = {"DATABASE_URL" => "postgres://u:pw@[broken/app"}
    secrets = Caramel::Crema::Redact.secrets(env)
    secrets.should contain("postgres://u:pw@[broken/app")
  end

  it "redacts more credential names, quoted names and bearer tokens" do
    text = %(passwd=a "api-key": "b" Authorization: Bearer c.d-e and Bearer f.g)
    redacted = Caramel::Crema::Redact.text(text, [] of String, 1000)
    ["passwd=a", %("b"), "c.d-e", "f.g"].each { |secret| redacted.should_not contain(secret) }
  end

  it "leaves credential-looking text alone when asked, still hiding secrets" do
    text = "password=visible token9"
    redacted = Caramel::Crema::Redact.text(text, ["token9"], 1000, credentials: false)
    redacted.should eq("password=visible [redacted]")
  end

  it "reduces a report to its class when it cannot be built" do
    report = Caramel::Crema::ErrorReport.minimal(KeyError.new("x"), false, "source")
    report.message.should eq("[unavailable]")
    report.fingerprint.should eq(Caramel::Crema::ErrorReport.fingerprint_of("KeyError", nil))
    report.backtrace.should be_empty
  end

  it "never puts the message in a production event" do
    event = report_of(KeyError.new("secret detail")).to_event(Caramel::Crema::Detail::Production)
    event.to_json.should_not contain("secret detail")
  end
end
