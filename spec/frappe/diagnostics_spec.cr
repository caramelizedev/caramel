require "spec"
require "../../src/frappe/diagnostics"

# spec/fixtures/compiler_output holds real compiler output for the failing
# fixtures, captured from the repository root with
#   scripts/crystal build spec/fixtures/<dir>/<name>.cr --no-codegen -D caramel_development
# with the checkout's absolute path replaced by @@ROOT@@.
private ROOT = File.expand_path("../..", __DIR__)

# Every captured fixture failure, by fixture directory and file: the MRDP
# code it maps to and the line and column it points at. Its output file is
# named <dir>_<file>.txt.
private CAPTURED = {
  "routes" => {
    "compile_ambiguous_order"        => {"COMPILE", "33:5"},
    "compile_defaulted_param"        => {"CONTRACT_MISMATCH", "5:5"},
    "compile_duplicate_route"        => {"COMPILE", "34:5"},
    "compile_missing_contract"       => {"COMPILE", "15:5"},
    "compile_missing_contract_field" => {"CONTRACT_MISMATCH", "5:5"},
    "compile_nilable_param"          => {"CONTRACT_MISMATCH", "5:5"},
    "compile_not_action"             => {"COMPILE", "10:5"},
    "compile_undefined_action"       => {"COMPILE", "18:5"},
    "compile_unknown_verb"           => {"COMPILE", "18:5"},
    "compile_wrong_param_type"       => {"CONTRACT_MISMATCH", "5:5"},
    "compile_wrong_path_id"          => {"NO_OVERLOAD", "8:17"},
  },
  "contracts" => {
    "compile_bounds_on_bool"   => {"COMPILE", "6:13"},
    "compile_unknown_access"   => {"UNDEFINED_METHOD", "10:44"},
    "compile_unsupported_type" => {"COMPILE", "6:13"},
  },
  "sugar_orm" => {
    "compile_missing_primary_key"       => {"COMPILE", "4:10"},
    "compile_n_plus_one"                => {"N_PLUS_ONE", "4:8"},
    "compile_non_literal_default"       => {"COMPILE", "6:11"},
    "compile_param_not_field"           => {"COMPILE", "4:9"},
    "compile_param_wrong_type"          => {"COMPILE", "4:9"},
    "compile_usage_n_plus_one"          => {"N_PLUS_ONE", "5:29"},
    "compile_unknown_changeset_keyword" => {"NO_OVERLOAD", "4:23"},
    "compile_unknown_facade_keyword"    => {"NO_OVERLOAD", "3:21"},
    "compile_unknown_order"             => {"NO_OVERLOAD", "3:44"},
    "compile_unknown_preload"           => {"NO_OVERLOAD", "3:20"},
    "compile_unknown_where_field"       => {"NO_OVERLOAD", "3:12"},
    "compile_unsupported_type"          => {"COMPILE", "6:11"},
    "compile_wrong_where_type"          => {"NO_OVERLOAD", "3:13"},
  },
  "diagnostics" => {
    "compile_syntax_error"       => {"SYNTAX", "10:5"},
    "compile_undefined_constant" => {"UNDEFINED_CONSTANT", "3:6"},
  },
}

private def diagnose(name : String) : Caramel::Frappe::Diagnostic
  path = File.join(ROOT, "spec/fixtures/compiler_output/#{name}.txt")
  output = File.read(path).gsub("@@ROOT@@", ROOT)
  diagnostics = Caramel::Frappe::Diagnostics.parse(output, ROOT, "src/app.cr")
  diagnostics.size.should eq(1)
  diagnostics.first
end

private def mrdp(diagnostic : Caramel::Frappe::Diagnostic) : String
  String.build { |io| diagnostic.to_mrdp(io) }
end

describe Caramel::Frappe::Diagnostics do
  it "classifies and locates every captured fixture failure" do
    CAPTURED.each do |directory, fixtures|
      fixtures.each do |file, (code, position)|
        name = "#{directory}_#{file}"
        location = "spec/fixtures/#{directory}/#{file}.cr:#{position}"
        diagnostic = diagnose(name)
        {name, diagnostic.code, diagnostic.location}.should eq({name, code, location})
      end
    end
    Dir.children(File.join(ROOT, "spec/fixtures/compiler_output")).size.should eq(29)
  end

  it "turns a missing route field into MRDP with a PATCH into the contract block" do
    diagnostic = diagnose("routes_compile_missing_contract_field")
    mrdp(diagnostic).should eq(<<-MRDP)
      ERR CONTRACT_MISMATCH:422 at spec/fixtures/routes/compile_missing_contract_field.cr:5:5
      NODE: RequestContract
      MISSING: team_id:Int64
      PATCH: INSERT "field team_id : Int64" AT 6:7\n
      MRDP
    declared = "Route '/teams/:team_id' is declared at " \
               "spec/fixtures/routes/compile_missing_contract_field.cr:18:5"
    diagnostic.details.should eq([declared])
  end

  it "reports a mistyped route field with its rule and fix but no patch" do
    mrdp(diagnose("routes_compile_wrong_param_type")).should eq(<<-MRDP)
      ERR CONTRACT_MISMATCH:422 at spec/fixtures/routes/compile_wrong_param_type.cr:5:5
      NODE: RequestContract
      MSG: Route '/teams/:team_id' parameter ':team_id' binds to 'TeamShow::Contract' \
        field 'team_id : Float64'
      FIX: declare `field team_id : Int64` (String, Int32 or Int64; no `?` and no `default:`).\n
      MRDP
  end

  it "reads the association and remedy from SugarORM's sentinel type " \
     "and patches a same-line query" do
    mrdp(diagnose("sugar_orm_compile_usage_n_plus_one")).should eq(<<-MRDP)
      ERR N_PLUS_ONE at spec/fixtures/sugar_orm/compile_usage_n_plus_one.cr:5:29
      MSG: Association 'users' of Team was not preloaded.
      PATCH: INSERT ".preload(:users)" AFTER 5:12\n
      MRDP
    # The query that loaded `team` is not on the accessing line.
    mrdp(diagnose("sugar_orm_compile_n_plus_one")).should eq(<<-MRDP)
      ERR N_PLUS_ONE at spec/fixtures/sugar_orm/compile_n_plus_one.cr:4:8
      MSG: Association 'users' of Team was not preloaded.
      FIX: add .preload(:users) to the query that loaded this Team, \
        e.g. Team.query.preload(:users).find(id)\n
      MRDP
  end

  it "keeps Caramel remediations, compiler hints and detail lines" do
    mrdp(diagnose("sugar_orm_compile_missing_primary_key")).should eq(<<-MRDP)
      ERR COMPILE at spec/fixtures/sugar_orm/compile_missing_primary_key.cr:4:10
      MSG: Keyless has no primary key.
      FIX: add `field id : Int64, primary: true` to the schema block of Keyless.\n
      MRDP
    constant = diagnose("diagnostics_compile_undefined_constant")
    expected_constant = {
      "undefined constant Caramel::Respons",
      "Did you mean 'Caramel::Response'?",
      16,
    }
    {constant.message, constant.remediation, constant.width}.should eq(expected_constant)
    overload = diagnose("routes_compile_wrong_path_id")
    expected_overload = {
      "expected argument #1 to 'Paths.book_path' to be Int64, not String",
      ["Overloads are:", "- Paths#book_path(id : Int64)"],
    }
    {overload.message, overload.details}.should eq(expected_overload)
    duplicate = "Duplicate route: 'GET /teams/:team_id' and 'GET /teams/:id' " \
                "match the same requests"
    diagnose("routes_compile_duplicate_route").message.should eq(duplicate)
    diagnose("contracts_compile_bounds_on_bool").details.should be_empty
    diagnose("diagnostics_compile_syntax_error").message.should eq("expecting token ')', not 'end'")
  end

  it "falls back to the entry point when the compiler names no location" do
    output = "Error: can't find file 'caramel'\n"
    diagnostic = Caramel::Frappe::Diagnostics.parse(output, ROOT, "src/app.cr").first
    expected = {"COMPILE", "src/app.cr", "can't find file 'caramel'"}
    {diagnostic.code, diagnostic.location, diagnostic.message}.should eq(expected)
  end

  it "renders the terminal typography, with ANSI only when asked" do
    diagnostic = diagnose("sugar_orm_compile_n_plus_one")
    plain = String.build { |io| diagnostic.render(io, color: false) }
    plain.should eq(<<-TEXT)
        ╭─[ spec/fixtures/sugar_orm/compile_n_plus_one.cr:4 ]
        │
        │  4 │   team.users.each do |user|
        │    │        ^^^^^ Association 'users' of Team was not preloaded.
        │
        ╰─ Accessing un-preloaded relationships triggers runtime N+1 queries.

           Remediation:
           Add .preload(:users) to the query that loaded this Team, \
             e.g. Team.query.preload(:users).find(id)\n
      TEXT
    colored = String.build { |io| diagnostic.render(io, color: true) }
    colored.should contain("\e[1;31m^^^^^\e[0m")
    colored.gsub(/\e\[[0-9;]*m/, "").should eq(plain)
  end
end
