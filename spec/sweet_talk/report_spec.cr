# The detailed glossary (ADR 0059): every glossary term with the facts its declaration
# holds, and the `glossary` command that prints it with the context map as JSON.
require "./support/app"

module ReportSpec
  def self.facts(kind : String, context : String, name : String) : Hash(String, Array(String))
    SweetTalk.report.find! do |entry|
      entry.term.kind == kind && entry.term.context == context && entry.term.name == name
    end.facts
  end
end

describe "SweetTalk.report" do
  it "holds every glossary term, in the glossary's order" do
    SweetTalk.report.map(&.term).should eq(SweetTalk.glossary)
  end

  it "holds a value's bounds and one_of: words" do
    ReportSpec.facts("value", "Invoicing", "Cents").should eq({
      "wraps" => ["Int64"], "at_least" => ["0"],
    })
    ReportSpec.facts("value", "Counter", "Currency")["one_of"].should eq(%w[USD EUR UZS])
  end

  it "holds an aggregate's states and the moves between them" do
    ReportSpec.facts("aggregate", "Invoicing", "Invoice").should eq({
      "states" => %w[open settled], "moves" => ["open >> settled"],
    })
  end

  it "holds an event's handlers in the order they run, each after: behind the one it names" do
    ReportSpec.facts("event", "Invoicing", "Invoice::Raised")["handlers"].should eq([
      "Owed", "Invoicing, after: Owed", "Nudges, after: Owed",
    ])
  end

  it "holds a unit's changes: and locks:, and the argument it runs once by" do
    ReportSpec.facts("unit", "Shelf", "tag_and_sign").should eq({
      "changes" => %w[Box Crate], "locks" => %w[box crate],
    })
    ReportSpec.facts("unit", "Shelf", "make_filled_pair")["locks"].should be_empty
    ReportSpec.facts("unit", "Shelf", "tag_once")["once_by"].should eq(["key"])
  end

  it "holds a context's follows: and shares:, and a kernel's sharers" do
    ReportSpec.facts("context", "Billing", "Billing").should eq({
      "follows" => ["Pricing"], "shares" => %w[Money Calendar],
    })
    ReportSpec.facts("kernel", "Money", "Money")["shared_by"].should eq(%w[Pricing Billing])
  end

  it "prints the report and the context map as JSON, and refuses any argument" do
    output, errors = IO::Memory.new, IO::Memory.new
    SweetTalk.__sweettalk_print_glossary([] of String, output, errors).should eq(0)
    printed = JSON.parse(output.to_s)
    printed["terms"].as_a.size.should eq(SweetTalk.glossary.size)
    raised = printed["terms"].as_a.find! do |term|
      term["kind"] == "event" && term["name"] == "Invoice::Raised"
    end
    raised["facts"]["handlers"][0].should eq("Owed")
    printed["map"].as_a.size.should eq(SweetTalk.context_map.size)
    SweetTalk.__sweettalk_print_glossary(["--json"], output, errors).should eq(2)
    errors.to_s.should eq("Usage: glossary\n")
  end
end
