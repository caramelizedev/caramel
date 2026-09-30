require "spec"
require "../../src/frappe/commands"

private def parse(*args : String) : Caramel::Frappe::Commands::Invocation
  Caramel::Frappe::Commands.parse(args.to_a)
end

private MIGRATE = "frappe migrate [--dev-override] [--agent|--human]"

private def refusal(*args : String) : Caramel::Frappe::Commands::Usage
  expect_raises(Caramel::Frappe::Commands::Usage) { Caramel::Frappe::Commands.parse(args.to_a) }
end

describe Caramel::Frappe::Commands do
  it "binds positionals, choices, repeated values and every option form" do
    dev = parse("dev", "--branch", "feature_x", "--no-open")
    dev.command.name.should eq("dev")
    dev["--branch"].should eq("feature_x")
    dev.flag?("--no-open").should be_true
    parse("dev").flag?("--no-open").should be_false

    make = parse("make", "resource", "Person", "name:string", "age:int32", "--plural=people")
    make.command.name.should eq("make resource")
    bound = {make["NAME"], make.list("FIELD:TYPE"), make["--plural"]}
    bound.should eq({"Person", ["name:string", "age:int32"], "people"})

    parse("db", "branch", "create", "feature_x")["NAME"].should eq("feature_x")
    parse("db", "diff", "--dev-override", "--name", "add_isbn")["--name"].should eq("add_isbn")
    parse("logs", "compiler", "--follow")["app|compiler"].should eq("compiler")
    parse("routes")["FILTER"]?.should be_nil
    parse("routes", "books")["FILTER"].should eq("books")
    corretto = parse("corretto", "spec/models", "spec/requests", "--concurrency=8")
    corretto.list("SPEC_PATHS").should eq(["spec/models", "spec/requests"])
    parse("sites", "remove", "shelf").command.name.should eq("sites remove")
    parse("sites").command.name.should eq("sites")
    parse("installations", "list").command.name.should eq("installations")
  end

  it "passes language-server arguments through verbatim, flags included" do
    server = parse("lsp", "ameba-ls", "--stdio", "--version")
    bound = {server["crystalline|ameba-ls"], server.list("SERVER_ARGS")}
    bound.should eq({"ameba-ls", ["--stdio", "--version"]})
    parse("lsp", "install").command.name.should eq("lsp install")
  end

  it "refuses malformed arguments with the intended command's exact syntax" do
    # Each command's syntax, and the message each malformed invocation of it gets.
    refusals = {
      "frappe new NAME" => {
        %w[new] => "missing NAME",
      },
      "frappe check [--agent|--human]" => {
        %w[check --agent --human] => "--agent and --human exclude each other",
      },
      MIGRATE => {
        %w[migrate --dev-override --dev-override] => "--dev-override is given more than once",
      },
      "frappe corretto [SPEC_PATHS...] [--concurrency=1..8]" => {
        %w[corretto --concurrency=9]  => "--concurrency must be a whole number from 1 to 8",
        %w[corretto --concurrency=+2] => "--concurrency must be a whole number from 1 to 8",
        %w[corretto --concurrency]    => "--concurrency needs a value: --concurrency=1..8",
        ["corretto", ""]              => "empty argument for SPEC_PATHS",
      },
      "frappe dev [--no-open] [--branch NAME]" => {
        %w[dev --branch]      => "--branch needs a value: --branch NAME",
        %w[dev --branch=x]    => "--branch needs a value: --branch NAME",
        %w[dev --no-open=yes] => "--no-open takes no value",
      },
      "frappe db diff --name NAME [--dev-override] [--agent|--human]" => {
        %w[db diff --name] => "--name needs a value: --name NAME",
        %w[db diff]        => "missing --name NAME",
      },
      "frappe db restore FILE" => {
        %w[db restore] => "missing FILE",
      },
      "frappe routes [FILTER]" => {
        %w[routes a b] => "unexpected argument \"b\"",
      },
      "frappe expand FILE:LINE:COL" => {
        %w[expand] => "missing FILE:LINE:COL",
      },
      "frappe make resource NAME FIELD:TYPE... [--plural=NAME] [--only=ACTIONS]" => {
        %w[make resource Book] => "missing FIELD:TYPE",
      },
    }
    refusals.each do |syntax, messages|
      messages.each do |arguments, message|
        error = expect_raises(Caramel::Frappe::Commands::Usage) do
          Caramel::Frappe::Commands.parse(arguments)
        end
        {error.message, error.syntax}.should eq({message, syntax})
      end
    end
  end

  it "suggests the nearest command, subcommand, choice or option" do
    unknown = refusal("migrte")
    expected = {"unknown command migrte", "migrate", MIGRATE}
    {unknown.message, unknown.suggestion, unknown.syntax}.should eq(expected)
    refusal("dev", "--branc", "x").suggestion.should eq("--branch")
    refusal("check", "--agnet").suggestion.should eq("--agent")
    refusal("logs", "complier").suggestion.should eq("compiler")
    branch = refusal("db", "branch", "craete", "x")
    {branch.message, branch.suggestion}.should eq({"unknown db branch subcommand craete", "create"})
    branch_syntax = "frappe db branch create NAME | frappe db branch list | " \
                    "frappe db branch delete NAME"
    branch.syntax.should eq(branch_syntax)
    refusal("db", "brnach").suggestion.should eq("branch")
    refusal("sites", "remvoe").suggestion.should eq("remove")
    nothing = refusal("zzzzzz")
    {nothing.suggestion, nothing.syntax}.should eq({nil, nil})
    lsp_syntax = "frappe lsp crystalline|ameba-ls [SERVER_ARGS...] | frappe lsp install"
    refusal("lsp").syntax.should eq(lsp_syntax)
    refusal("db").message.should eq("frappe db needs a subcommand")
  end

  it "knows which invocations belong to a project" do
    Caramel::Frappe::Commands.project?(["lsp", "crystalline"]).should be_true
    Caramel::Frappe::Commands.project?(["lsp", "install"]).should be_false
    Caramel::Frappe::Commands.project?(["sites", "remove", "x"]).should be_false
    Caramel::Frappe::Commands.project?(["db"]).should be_true
    Caramel::Frappe::Commands.project?(["bogus"]).should be_false
    branches = ["db branch create", "db branch list", "db branch delete"]
    Caramel::Frappe::Commands.matching(["db", "branch"]).map(&.name).should eq(branches)
  end

  it "declares every command only once" do
    names = Caramel::Frappe::Commands::TABLE.map(&.name)
    names.uniq.size.should eq(names.size)
  end
end
