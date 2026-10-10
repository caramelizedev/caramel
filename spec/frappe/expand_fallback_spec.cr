require "spec"
require "../../src/frappe/expand_fallback"

private alias Fallback = Caramel::Frappe::ExpandFallback

private NOTES = <<-CR
  module App
    struct Notes < Caramel::Action
      # contract do is not a call
      contract do
        field title : String, min: 1, max: 200
        items.each { |item| field item, text: "do end" }
        field body : String
      end

      def handle(contract : Contract)
        helper(1)
      end
    end
  end
  CR

private OUTPUT = <<-TXT
  1 expansion found
  expansion 1:
     contract do
       field(title : String, min: 1, max: 200)
       field(body : String)
     end

  # expand macro 'contract' (action.cr:30:5)
  ~> struct Contract
       field(title : String, min: 1, max: 200)
       field(body : String)
     end

  # expand macro 'field' (request_contract.cr:97:5)
  ~> struct Contract
       CARAMEL_FIELD_TITLE = {"title"}
       field(body : String)
     end

  # expand macro 'field' (request_contract.cr:97:5)
  ~> struct Contract
       CARAMEL_FIELD_TITLE = {"title"}
       CARAMEL_FIELD_BODY = {"body"}
     end

  TXT

private SHARED = <<-TXT
  1 expansion found
  expansion 1:
     contract do
       field(title : String)
       field(body : String)
     end

  # expand macro 'contract' (action.cr:30:5)
  ~> struct Contract
       field(title : String)
       field(body : String)
     end

  # expand macro 'field' (request_contract.cr:97:5)
  # expand macro 'field' (request_contract.cr:97:5)
  ~> struct Contract
       CARAMEL_FIELD_TITLE = {"title"}
       CARAMEL_FIELD_BODY = {"body"}
     end

  TXT

describe Caramel::Frappe::ExpandFallback do
  it "names the calls whose block encloses a position, innermost first" do
    inner = Fallback.enclosing(NOTES, 6, 25)
    inner.map { |entry| {entry.name, entry.line, entry.column} }
      .should eq([{"each", 6, 13}, {"contract", 4, 5}])
    Fallback.enclosing(NOTES, 5, 7).map(&.name).should eq(["contract"])
  end

  it "ignores a position on the call's own name, outside any block, or in a def" do
    Fallback.enclosing(NOTES, 4, 6).should be_empty
    Fallback.enclosing(NOTES, 11, 6).should be_empty
    Fallback.enclosing("foo(1)\nbar do\nend\n", 1, 2).should be_empty
    Fallback.enclosing("def broken(", 1, 2).should be_empty
  end

  it "finds a receiver call by the position the compiler matches" do
    source = "Caramel::Router.draw do\n  get \"/\"\nend\n"
    Fallback.enclosing(source, 2, 3).map { |entry| {entry.name, entry.line, entry.column} }
      .should eq([{"draw", 1, 1}])
  end

  it "reads the call that the compiler reports as not expanding" do
    message = "no expansion found: field(title : String, min: 1, max: 200) may not be a macro\n"
    Fallback.unexpanded_call(message).should eq("field(title : String, min: 1, max: 200)")
    Fallback.unexpanded_call("no expansion found\n").should be_nil
    Fallback.found?(message).should be_false
    Fallback.found?(OUTPUT).should be_true
  end

  it "keeps the steps up to the one that expands the requested call" do
    trimmed = Fallback.trim(OUTPUT, "field(title : String, min: 1, max: 200)").not_nil!
    trimmed.should contain("# expand macro 'contract'")
    trimmed.should contain("CARAMEL_FIELD_TITLE")
    trimmed.scan("# expand macro 'field'").size.should eq(1)
    trimmed.should_not contain("CARAMEL_FIELD_BODY")
    trimmed.should start_with("1 expansion found\nexpansion 1:")
    Fallback.trim(OUTPUT, "field(body : String)").not_nil!.should contain("CARAMEL_FIELD_BODY")
  end

  it "refuses an expansion that never consumes the requested call" do
    Fallback.trim(OUTPUT, "helper(1)").should be_nil
    Fallback.trim(OUTPUT, nil).should eq(OUTPUT)
  end

  it "treats consecutive headers as one step with a shared body" do
    trimmed = Fallback.trim(SHARED, "field(title : String)").not_nil!
    trimmed.scan("# expand macro 'field'").size.should eq(2)
    trimmed.should contain("CARAMEL_FIELD_BODY")
  end
end
