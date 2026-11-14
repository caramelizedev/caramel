require "spec"
require "../../src/caramel"

private JOURNAL = ["LEDGER-1", "LEDGER-2"]
private CLOSING = ["LEDGER-2", "LEDGER-3"]
private LEDGER  = ["LEDGER-1", "LEDGER-2", "LEDGER-3"]

Caramel::SpecIds.declare { JOURNAL }
Caramel::SpecIds.declare { CLOSING }

# The ledger's ids among *ids*, which hold every library's in one spec binary.
private def ledger(ids : Array(String)) : Array(String)
  ids.select(&.starts_with?("LEDGER-"))
end

describe Caramel::SpecIds do
  it "lists every declared id once, in the order the sources were declared" do
    ledger(Caramel::SpecIds.all).should eq(LEDGER)
  end

  it "asks each source again whenever the ids are read" do
    seasons = ["SEASON-1"]
    Caramel::SpecIds.declare { seasons }
    Caramel::SpecIds.all.should contain("SEASON-1")
    seasons << "SEASON-2"
    Caramel::SpecIds.all.should contain("SEASON-2")
  end
end

describe "The application's spec-ids command" do
  it "prints each id on a line of its own and returns 0" do
    output = IO::Memory.new
    Caramel::CommandLine.spec_ids(output).should eq(0)
    ledger(output.to_s.lines).should eq(LEDGER)
  end
end
