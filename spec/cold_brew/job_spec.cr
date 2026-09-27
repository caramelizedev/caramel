require "spec"
require "../../src/caramel"

module ColdBrewUnit
  class Bounce < Exception
  end

  class Outage < Exception
  end

  Caramel::ColdBrew::Job.retry_on ColdBrewUnit::Outage, attempts: 6, backoff: :linear, base: 3.seconds

  class_getter performed = [] of String

  struct Echo < Caramel::ColdBrew::Job
    param label : String
    param copies : Int32 = 1
    param note : String? = nil

    def perform
      ColdBrewUnit.performed << "#{label}x#{copies}#{note ? " (#{note})" : ""}"
    end
  end

  abstract struct MailJob < Caramel::ColdBrew::Job
    queue "mailers"
    retry_on ColdBrewUnit::Bounce, attempts: 7, backoff: :linear, base: 10.seconds
  end

  struct Welcome < MailJob
    retry_on ColdBrewUnit::Outage, attempts: 2, backoff: :exponential, base: 1.minute

    def perform
    end
  end
end

private def rule(backoff : Caramel::ColdBrew::Backoff, base : Time::Span) : Caramel::ColdBrew::RetryRule
  Caramel::ColdBrew::RetryRule.new(->(_error : Exception) { true }, 5, backoff, base)
end

describe Caramel::ColdBrew::RetryRule do
  it "waits base * 2**(attempt - 1) for exponential and base * attempt for linear backoff" do
    exponential = rule(:exponential, 2.seconds)
    (1..4).map { |attempt| exponential.delay(attempt) }.should eq([2.seconds, 4.seconds, 8.seconds, 16.seconds])
    linear = rule(:linear, 2.seconds)
    (1..4).map { |attempt| linear.delay(attempt) }.should eq([2.seconds, 4.seconds, 6.seconds, 8.seconds])
  end

  it "caps the exponent instead of overflowing on a long retry policy" do
    rule(:exponential, 1.second).delay(64).should eq(1.second * (2_i64 ** 30))
  end
end

describe Caramel::ColdBrew::Retry do
  it "prefers the job's own rule, then its abstract parent's, then the global one, then 3 exponential attempts from 1 second" do
    lineage = Caramel::ColdBrew::Job.__cold_brew_lineage("ColdBrewUnit::Welcome")
    lineage.should eq(["ColdBrewUnit::Welcome", "ColdBrewUnit::MailJob"])
    own = Caramel::ColdBrew::Retry.rule_for(lineage, ColdBrewUnit::Outage.new)
    {own.attempts, own.backoff, own.base}.should eq({2, Caramel::ColdBrew::Backoff::Exponential, 1.minute})
    parent = Caramel::ColdBrew::Retry.rule_for(lineage, ColdBrewUnit::Bounce.new)
    {parent.attempts, parent.backoff, parent.base}.should eq({7, Caramel::ColdBrew::Backoff::Linear, 10.seconds})
    global = Caramel::ColdBrew::Retry.rule_for(Caramel::ColdBrew::Job.__cold_brew_lineage("ColdBrewUnit::Echo"), ColdBrewUnit::Outage.new)
    {global.attempts, global.backoff, global.base}.should eq({6, Caramel::ColdBrew::Backoff::Linear, 3.seconds})
    fallback = Caramel::ColdBrew::Retry.rule_for(lineage, KeyError.new)
    {fallback.attempts, fallback.backoff, fallback.base}.should eq({3, Caramel::ColdBrew::Backoff::Exponential, 1.second})
  end
end

describe Caramel::ColdBrew::Job do
  it "inherits its queue from an abstract parent and defaults to default" do
    ColdBrewUnit::Welcome.queue_name.should eq("mailers")
    ColdBrewUnit::Echo.queue_name.should eq("default")
  end

  it "stores typed params as the JSON payload that the registry decodes and performs by class name" do
    payload = ColdBrewUnit::Echo.new(label: "hello", copies: 2, note: "draft").to_json
    JSON.parse(payload).should eq(JSON.parse(%({"label":"hello","copies":2,"note":"draft"})))
    ColdBrewUnit.performed.clear
    Caramel::ColdBrew::Job.__cold_brew_perform("ColdBrewUnit::Echo", payload)
    Caramel::ColdBrew::Job.__cold_brew_perform("ColdBrewUnit::Echo", %({"label":"bare","copies":1}))
    ColdBrewUnit.performed.should eq(["hellox2 (draft)", "barex1"])
  end

  it "refuses a class name that no compiled job has" do
    expect_raises(Caramel::ColdBrew::UnknownJob, "No Caramel::ColdBrew::Job named Gone::Job") do
      Caramel::ColdBrew::Job.__cold_brew_perform("Gone::Job", "{}")
    end
  end
end

describe Caramel::ColdBrew::Queue do
  it "describes a failure by class and message within the error limit" do
    Caramel::ColdBrew::Queue.describe(ColdBrewUnit::Bounce.new("mailbox full")).should start_with("ColdBrewUnit::Bounce: mailbox full")
    Caramel::ColdBrew::Queue.describe(ColdBrewUnit::Bounce.new("x" * 10_000)).size.should eq(Caramel::ColdBrew::Queue::ERROR_LIMIT)
  end
end
