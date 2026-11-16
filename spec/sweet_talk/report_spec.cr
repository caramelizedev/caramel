# The detailed glossary (ADR 0036): every glossary term with the facts its declaration
# holds, and the `sweettalk:glossary` and `sweettalk:contexts` commands that print it and
# the context map.
require "./support/app"

module ReportSpec
  def self.facts(kind : String, context : String, name : String) : Hash(String, Array(String))
    SweetTalk.report.find! do |entry|
      entry.term.kind == kind && entry.term.context == context && entry.term.name == name
    end.facts
  end

  def self.entry(kind : String, name : String, context : String, means : String,
                 subdomain : String?, facts : Hash(String, Array(String))) : SweetTalk::Entry
    SweetTalk::Entry.new(SweetTalk::Term.new(kind, name, context, means, subdomain), facts)
  end

  NONE = [] of String

  # A report written by hand: a kernel and two contexts, with a term of two of them.
  ENTRIES = [
    entry("kernel", "Money", "Money", "money we agree on", nil,
      {"follows" => NONE, "shares" => NONE, "shared_by" => ["Pricing", "Billing"]}),
    entry("value", "Cents", "Money", "an amount | in cents", nil,
      {"wraps" => ["Int64"], "at_least" => ["0"]}),
    entry("context", "Billing", "Billing", "billing guests", "core",
      {"follows" => ["Pricing"], "shares" => ["Money"]}),
    entry("event", "Bill::Paid", "Billing", "a bill was paid", "core",
      {"handlers" => ["Owed", "Billing, after: Owed"]}),
    entry("context", "Pricing", "Pricing", "setting prices", nil,
      {"follows" => NONE, "shares" => ["Money"]}),
  ]

  # The context map of that report.
  EDGES = [
    {"Billing", "Pricing", "dependency"}, {"Billing", "Pricing", "event"},
    {"Pricing", "Money", "kernel"}, {"Billing", "Cards", "outside"},
  ]
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

  it "prints the glossary as Markdown, with --json the report and the context map, " \
     "and refuses any other argument" do
    output, errors = IO::Memory.new, IO::Memory.new
    SweetTalk.__sweettalk_print_glossary([] of String, output, errors).should eq(0)
    output.to_s.should eq(SweetTalk.__sweettalk_glossary_markdown(SweetTalk.report))
    output.to_s.should start_with("# Glossary\n\n## ")
    output.clear
    SweetTalk.__sweettalk_print_glossary(["--json"], output, errors).should eq(0)
    printed = JSON.parse(output.to_s)
    printed["terms"].as_a.size.should eq(SweetTalk.glossary.size)
    raised = printed["terms"].as_a.find! do |term|
      term["kind"] == "event" && term["name"] == "Invoice::Raised"
    end
    raised["facts"]["handlers"][0].should eq("Owed")
    printed["map"].as_a.size.should eq(SweetTalk.context_map.size)
    SweetTalk.__sweettalk_print_glossary(["--mermaid"], output, errors).should eq(2)
    errors.to_s.should eq("Usage: sweettalk:glossary [--json]\n")
  end

  it "prints the context map as text, with --mermaid as a flowchart, " \
     "and refuses any other argument" do
    output, errors = IO::Memory.new, IO::Memory.new
    SweetTalk.__sweettalk_print_contexts([] of String, output, errors).should eq(0)
    output.to_s.should eq(SweetTalk.__sweettalk_map_text(SweetTalk.report, SweetTalk.context_map))
    output.to_s.should contain("  depends on Pricing\n")
    output.clear
    SweetTalk.__sweettalk_print_contexts(["--mermaid"], output, errors).should eq(0)
    output.to_s.should start_with("flowchart LR\n")
    SweetTalk.__sweettalk_print_contexts(["--json"], output, errors).should eq(2)
    errors.to_s.should eq("Usage: sweettalk:contexts [--mermaid]\n")
  end

  it "registers its three commands under the shard's name" do
    names = %w[sweettalk:requirements sweettalk:glossary sweettalk:contexts]
    (Caramel::Crema.command_names & names).should eq(names)
  end
end

describe "SweetTalk's glossary, printed" do
  it "has one section per context or kernel, with its terms and their facts" do
    SweetTalk.__sweettalk_glossary_markdown(ReportSpec::ENTRIES).should eq(<<-MARKDOWN)
      # Glossary

      ## Money (kernel)

      money we agree on

      shared_by: Pricing, Billing

      | Term | Kind | Means | Facts |
      | --- | --- | --- | --- |
      | Cents | value | an amount \\| in cents | wraps: Int64; at_least: 0 |

      ## Billing (context, core)

      billing guests

      follows: Pricing; shares: Money

      | Term | Kind | Means | Facts |
      | --- | --- | --- | --- |
      | Bill::Paid | event | a bill was paid | handlers: Owed, Billing, after: Owed |

      ## Pricing (context)

      setting prices

      shares: Money

      MARKDOWN
  end

  it "has the context map as text, each module with the edges that leave it" do
    text = SweetTalk.__sweettalk_map_text(ReportSpec::ENTRIES, ReportSpec::EDGES)
    text.should eq(<<-TEXT)
      Money
      Billing
        depends on Pricing
        reacts to Pricing
        calls Cards
      Pricing
        shares Money

      TEXT
  end

  it "has the context map as a Mermaid flowchart" do
    mermaid = SweetTalk.__sweettalk_map_mermaid(ReportSpec::ENTRIES, ReportSpec::EDGES)
    mermaid.should eq(<<-MERMAID)
      flowchart LR
        Money
        Billing
        Pricing
        Billing -->|depends on| Pricing
        Billing -.->|reacts to| Pricing
        Pricing ---|shares| Money
        Billing -->|calls| Cards{{Cards}}

      MERMAID
  end
end
