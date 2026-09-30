require "spec"
require "../../src/caramel"

# A URL whose socket directory does not exist: any attempt to connect fails
# with a different error than the validation under test.
private UNREACHABLE = "postgresql://nobody@/nowhere?host=/nonexistent-caramel-socket"

describe "Caramel::ColdBrew PubSub validation" do
  it "accepts channel names of 1-63 characters from [a-z0-9_.:-] only" do
    %w[board_1 a.b:c-d x].each { |name| Caramel::ColdBrew.validate_channel!(name) }
    ["", "Board_1", "board 1", %(board"1), "board;1", "x" * 64].each do |name|
      expect_raises(ArgumentError, "PubSub channel names") do
        Caramel::ColdBrew.validate_channel!(name)
      end
    end
  end

  it "refuses an invalid channel or a payload over 8000 bytes before touching the database" do
    expect_raises(ArgumentError, "PubSub channel names") do
      Caramel::ColdBrew.publish("Board 1", "{}")
    end
    expect_raises(ArgumentError, "8000 bytes, got 8002") do
      Caramel::ColdBrew.publish("board_1", "é" * 4001)
    end
  end

  it "explains how to configure a broker when none is running" do
    previous = Caramel::ColdBrew.broker?
    Caramel::ColdBrew.broker = nil
    begin
      expect_raises(Caramel::ColdBrew::ConfigurationError, "Caramel::ColdBrew.start") do
        Caramel::ColdBrew.subscribe("board_1", Channel(String).new)
      end
    ensure
      Caramel::ColdBrew.broker = previous
    end
  end
end

describe "Caramel::ColdBrew.start settings" do
  it "rejects worker settings before it connects" do
    two_queues = {
      "CARAMEL_WORKER_QUEUES"      => "default,mailers",
      "CARAMEL_WORKER_CONCURRENCY" => "16",
    }
    [
      { {"CARAMEL_WORKER_CONCURRENCY" => "0"}, "from 1 to 31 for 1 queue(s)" },
      { {"CARAMEL_WORKER_CONCURRENCY" => "four"}, "from 1 to 31 for 1 queue(s)" },
      { {"CARAMEL_WORKER_CONCURRENCY" => "32"}, "from 1 to 31 for 1 queue(s)" },
      {two_queues, "from 1 to 15 for 2 queue(s)"},
      { {"CARAMEL_WORKER_QUEUES" => "default, default"}, "names a queue twice" },
      { {"CARAMEL_WORKER_QUEUES" => "default,,mailers"}, %(got "") },
      { {"CARAMEL_WORKER_QUEUES" => "Mailers"}, %(got "Mailers") },
    ].each do |env, message|
      expect_raises(Caramel::ColdBrew::ConfigurationError, message) do
        Caramel::ColdBrew.start(UNREACHABLE, env)
      end
    end
  end
end

private alias WorkOptions = Caramel::CommandLine::WorkOptions

describe WorkOptions do
  it "reads work's flags and refuses unknown, repeated or empty ones" do
    WorkOptions.parse([] of String).should eq(WorkOptions.new)
    flags = ["--queues=mailers,default", "--concurrency=8", "--no-scheduler"]
    WorkOptions.parse(flags).should eq(WorkOptions.new("mailers,default", "8", false))

    refused = [
      %w[--queues=],
      %w[--queues],
      %w[--concurrency=],
      %w[--no-scheduler=yes],
      %w[--threads=2],
      %w[--queues=a --queues=b],
      %w[serve],
    ]
    refused.each { |arguments| WorkOptions.parse(arguments).should be_nil }
  end

  it "applies its flags over the worker settings ColdBrew.start validates" do
    env = {
      "CARAMEL_WORKER_QUEUES"      => "default",
      "CARAMEL_WORKER_CONCURRENCY" => "4",
      "APP_SECRET"                 => "kept",
    }
    WorkOptions.new.environment(env).should eq(env)

    applied = WorkOptions.new("mailers", "32").environment(env)
    applied.should eq({
      "CARAMEL_WORKER_QUEUES"      => "mailers",
      "CARAMEL_WORKER_CONCURRENCY" => "32",
      "APP_SECRET"                 => "kept",
    })
    expect_raises(Caramel::ColdBrew::ConfigurationError, "from 1 to 31 for 1 queue(s)") do
      Caramel::ColdBrew.start(UNREACHABLE, applied, scheduler: false)
    end
  end
end

describe "Caramel::ColdBrew.every" do
  it "refuses spans under a second, blank names and duplicate names" do
    expect_raises(ArgumentError, "at least 1 second") do
      Caramel::ColdBrew.every(500.milliseconds, "too-fast") { }
    end
    expect_raises(ArgumentError, "schedule name") do
      Caramel::ColdBrew.every(1.minute, " ") { }
    end
    Caramel::ColdBrew.every(1.hour, "unit-spec-report") { }
    expect_raises(ArgumentError, %(named "unit-spec-report" already exists)) do
      Caramel::ColdBrew.every(2.hours, "unit-spec-report") { }
    end
  end
end

describe "Caramel::Cache.write" do
  it "refuses an expiry that is not in the future" do
    expect_raises(ArgumentError, "expires_in must be positive") do
      Caramel::Cache.write("key", "value", expires_in: Time::Span.zero)
    end
    expect_raises(ArgumentError, "expires_in must be positive") do
      Caramel::Cache.write("key", "value", expires_in: -1.second)
    end
  end
end
