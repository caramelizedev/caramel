require "spec"
require "../../src/frappe/diagnostics"

# spec/fixtures/compiler_output holds real compiler output for the failing
# fixtures, captured from the repository root with
#   scripts/crystal build spec/fixtures/<dir>/<name>.cr --no-codegen -D caramel_development
# with the checkout's absolute path replaced by @@ROOT@@.
private ROOT = File.expand_path("../..", __DIR__)

private def diagnose(name : String) : Caramel::Frappe::Diagnostic
  output = File.read(File.join(ROOT, "spec/fixtures/compiler_output/#{name}.txt")).gsub("@@ROOT@@", ROOT)
  diagnostics = Caramel::Frappe::Diagnostics.parse(output, ROOT, "src/app.cr")
  diagnostics.size.should eq(1)
  diagnostics.first
end

private def mrdp(diagnostic : Caramel::Frappe::Diagnostic) : String
  String.build { |io| diagnostic.to_mrdp(io) }
end

describe Caramel::Frappe::Diagnostics do
  it "classifies and locates every captured fixture failure" do
    {
      "routes_compile_ambiguous_order"             => {"COMPILE", "spec/fixtures/routes/compile_ambiguous_order.cr:33:5"},
      "routes_compile_defaulted_param"             => {"CONTRACT_MISMATCH", "spec/fixtures/routes/compile_defaulted_param.cr:5:5"},
      "routes_compile_duplicate_route"             => {"COMPILE", "spec/fixtures/routes/compile_duplicate_route.cr:34:5"},
      "routes_compile_missing_contract"            => {"COMPILE", "spec/fixtures/routes/compile_missing_contract.cr:15:5"},
      "routes_compile_missing_contract_field"      => {"CONTRACT_MISMATCH", "spec/fixtures/routes/compile_missing_contract_field.cr:5:5"},
      "routes_compile_nilable_param"               => {"CONTRACT_MISMATCH", "spec/fixtures/routes/compile_nilable_param.cr:5:5"},
      "routes_compile_not_action"                  => {"COMPILE", "spec/fixtures/routes/compile_not_action.cr:10:5"},
      "routes_compile_undefined_action"            => {"COMPILE", "spec/fixtures/routes/compile_undefined_action.cr:18:5"},
      "routes_compile_unknown_verb"                => {"COMPILE", "spec/fixtures/routes/compile_unknown_verb.cr:18:5"},
      "routes_compile_wrong_param_type"            => {"CONTRACT_MISMATCH", "spec/fixtures/routes/compile_wrong_param_type.cr:5:5"},
      "routes_compile_wrong_path_id"               => {"NO_OVERLOAD", "spec/fixtures/routes/compile_wrong_path_id.cr:8:17"},
      "contracts_compile_bounds_on_bool"           => {"COMPILE", "spec/fixtures/contracts/compile_bounds_on_bool.cr:6:13"},
      "contracts_compile_unknown_access"           => {"UNDEFINED_METHOD", "spec/fixtures/contracts/compile_unknown_access.cr:10:44"},
      "contracts_compile_unsupported_type"         => {"COMPILE", "spec/fixtures/contracts/compile_unsupported_type.cr:6:13"},
      "sugar_orm_compile_missing_primary_key"      => {"COMPILE", "spec/fixtures/sugar_orm/compile_missing_primary_key.cr:4:10"},
      "sugar_orm_compile_n_plus_one"               => {"N_PLUS_ONE", "spec/fixtures/sugar_orm/compile_n_plus_one.cr:4:8"},
      "sugar_orm_compile_non_literal_default"      => {"COMPILE", "spec/fixtures/sugar_orm/compile_non_literal_default.cr:6:11"},
      "sugar_orm_compile_param_not_field"          => {"COMPILE", "spec/fixtures/sugar_orm/compile_param_not_field.cr:4:9"},
      "sugar_orm_compile_param_wrong_type"         => {"COMPILE", "spec/fixtures/sugar_orm/compile_param_wrong_type.cr:4:9"},
      "sugar_orm_compile_rfc_n_plus_one"           => {"N_PLUS_ONE", "spec/fixtures/sugar_orm/compile_rfc_n_plus_one.cr:5:29"},
      "sugar_orm_compile_unknown_changeset_keyword" => {"NO_OVERLOAD", "spec/fixtures/sugar_orm/compile_unknown_changeset_keyword.cr:4:23"},
      "sugar_orm_compile_unknown_facade_keyword"   => {"NO_OVERLOAD", "spec/fixtures/sugar_orm/compile_unknown_facade_keyword.cr:3:21"},
      "sugar_orm_compile_unknown_order"            => {"NO_OVERLOAD", "spec/fixtures/sugar_orm/compile_unknown_order.cr:3:44"},
      "sugar_orm_compile_unknown_preload"          => {"NO_OVERLOAD", "spec/fixtures/sugar_orm/compile_unknown_preload.cr:3:20"},
      "sugar_orm_compile_unknown_where_field"      => {"NO_OVERLOAD", "spec/fixtures/sugar_orm/compile_unknown_where_field.cr:3:12"},
      "sugar_orm_compile_unsupported_type"         => {"COMPILE", "spec/fixtures/sugar_orm/compile_unsupported_type.cr:6:11"},
      "sugar_orm_compile_wrong_where_type"         => {"NO_OVERLOAD", "spec/fixtures/sugar_orm/compile_wrong_where_type.cr:3:13"},
      "diagnostics_compile_syntax_error"           => {"SYNTAX", "spec/fixtures/diagnostics/compile_syntax_error.cr:10:5"},
      "diagnostics_compile_undefined_constant"     => {"UNDEFINED_CONSTANT", "spec/fixtures/diagnostics/compile_undefined_constant.cr:3:6"},
    }.each do |name, (code, location)|
      diagnostic = diagnose(name)
      {name, diagnostic.code, diagnostic.location}.should eq({name, code, location})
    end
    Dir.children(File.join(ROOT, "spec/fixtures/compiler_output")).size.should eq(29)
  end

  it "turns a missing route field into the RFC's MRDP with a PATCH into the contract block" do
    diagnostic = diagnose("routes_compile_missing_contract_field")
    mrdp(diagnostic).should eq(<<-MRDP)
      ERR CONTRACT_MISMATCH:422 at spec/fixtures/routes/compile_missing_contract_field.cr:5:5
      NODE: RequestContract
      MISSING: team_id:Int64
      PATCH: INSERT "field team_id : Int64" AT 6:7\n
      MRDP
    diagnostic.details.should eq(["Route '/teams/:team_id' is declared at spec/fixtures/routes/compile_missing_contract_field.cr:18:5"])
  end

  it "reports a mistyped route field with its rule and fix but no patch" do
    mrdp(diagnose("routes_compile_wrong_param_type")).should eq(<<-MRDP)
      ERR CONTRACT_MISMATCH:422 at spec/fixtures/routes/compile_wrong_param_type.cr:5:5
      NODE: RequestContract
      MSG: Route '/teams/:team_id' parameter ':team_id' binds to 'TeamShow::Contract' field 'team_id : Float64'
      FIX: declare `field team_id : Int64` (String, Int32 or Int64; no `?` and no `default:`).\n
      MRDP
  end

  it "reads the association and remedy from SugarORM's sentinel type and patches a same-line query" do
    mrdp(diagnose("sugar_orm_compile_rfc_n_plus_one")).should eq(<<-MRDP)
      ERR N_PLUS_ONE at spec/fixtures/sugar_orm/compile_rfc_n_plus_one.cr:5:29
      MSG: Association 'users' of Team was not preloaded.
      PATCH: INSERT ".preload(:users)" AFTER 5:12\n
      MRDP
    # The query that loaded `team` is not on the accessing line.
    mrdp(diagnose("sugar_orm_compile_n_plus_one")).should eq(<<-MRDP)
      ERR N_PLUS_ONE at spec/fixtures/sugar_orm/compile_n_plus_one.cr:4:8
      MSG: Association 'users' of Team was not preloaded.
      FIX: add .preload(:users) to the query that loaded this Team, e.g. Team.query.preload(:users).find(id)\n
      MRDP
  end

  it "keeps Caramel remediations, compiler hints and detail lines" do
    mrdp(diagnose("sugar_orm_compile_missing_primary_key")).should eq(<<-MRDP)
      ERR COMPILE at spec/fixtures/sugar_orm/compile_missing_primary_key.cr:4:10
      MSG: Keyless has no primary key.
      FIX: add `field id : Int64, primary: true` to the schema block of Keyless.\n
      MRDP
    constant = diagnose("diagnostics_compile_undefined_constant")
    {constant.message, constant.remediation, constant.width}.should eq({"undefined constant Caramel::Respons", "Did you mean 'Caramel::Response'?", 16})
    overload = diagnose("routes_compile_wrong_path_id")
    {overload.message, overload.details}.should eq({"expected argument #1 to 'Paths.book_path' to be Int64, not String", ["Overloads are:", "- Paths#book_path(id : Int64)"]})
    diagnose("routes_compile_duplicate_route").message.should eq("Duplicate route: 'GET /teams/:team_id' and 'GET /teams/:id' match the same requests")
    diagnose("contracts_compile_bounds_on_bool").details.should be_empty
    diagnose("diagnostics_compile_syntax_error").message.should eq("expecting token ')', not 'end'")
  end

  it "falls back to the entry point when the compiler names no location" do
    diagnostic = Caramel::Frappe::Diagnostics.parse("Error: can't find file 'caramel'\n", ROOT, "src/app.cr").first
    {diagnostic.code, diagnostic.location, diagnostic.message}.should eq({"COMPILE", "src/app.cr", "can't find file 'caramel'"})
  end

  it "renders the RFC-0008 typography, with ANSI only when asked" do
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
           Add .preload(:users) to the query that loaded this Team, e.g. Team.query.preload(:users).find(id)\n
      TEXT
    colored = String.build { |io| diagnostic.render(io, color: true) }
    colored.should contain("\e[1;31m^^^^^\e[0m")
    colored.gsub(/\e\[[0-9;]*m/, "").should eq(plain)
  end
end
