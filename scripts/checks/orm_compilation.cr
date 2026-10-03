require "./support/harness"

# Each misuse of the SugarORM DSL must fail to compile at the user's line with
# a remediation. Schema and changeset declaration errors name the exact line
# with `-->` (Crystal reports class-body macro errors on the class line).
cases = {
  "compile_valid"            => nil,
  "compile_usage_examples"   => nil,
  "compile_usage_n_plus_one" => [
    "compile_usage_n_plus_one.cr:5:35",
    "undefined method 'each' for Team::UsersNotLoaded",
    "Association 'users' of Team was not preloaded",
    ".preload(:users)",
  ],
  "compile_n_plus_one" => [
    "compile_n_plus_one.cr:4:",
    "undefined method 'each' for Team::UsersNotLoaded",
    "Association 'users' of Team was not preloaded",
    "Remediation: add .preload(:users) to the query that loaded this Team",
  ],
  "compile_unknown_preload" => [
    "compile_unknown_preload.cr:3:",
    "Team::QueryOf(NamedTuple())#preload",
    "Team::QueryOf::PreloadOwner, Team::QueryOf::PreloadProfile " \
    "or Team::QueryOf::PreloadUsers, not Symbol",
  ],
  "compile_unknown_where_field" => [
    "compile_unknown_where_field.cr:3:",
    "no parameter named 'title'",
    "Overloads are:",
    "name : ::String | Array(::String)",
  ],
  "compile_wrong_where_type" => [
    "compile_wrong_where_type.cr:3:",
    "no overload matches 'Team::QueryOf(NamedTuple()).where', seats: String",
    "seats : ::Int32 | Array(::Int32) | Range(::Int32, ::Int32)",
  ],
  "compile_unknown_order" => [
    "compile_unknown_order.cr:3:44",
    "expected argument #1 to 'Team::QueryOf(NamedTuple())#order_by' " \
    "to match a member of enum Team::Field",
    "Options are: :id, :name, :seats",
  ],
  "compile_param_not_field" => [
    "compile_param_not_field.cr:4:9",
    "param 'nickname' is not a field of Team",
    "Remediation: rename the param to one of these fields",
  ],
  "compile_param_wrong_type" => [
    "compile_param_wrong_type.cr:4:9",
    "param 'seats : String' does not match Team field 'seats : Int32'",
    "Remediation: declare `param seats : Int32`",
  ],
  "compile_unknown_changeset_keyword" => [
    "compile_unknown_changeset_keyword.cr:4:",
    "no parameter named 'name'",
    "Team::UpdateChangeset.new(record : ::Team, *, seats : ::Int32",
  ],
  "compile_unknown_facade_keyword" => [
    "compile_unknown_facade_keyword.cr:3:",
    "no overload matches 'Team#update', name: String",
    "Team#update(*, seats : ::Int32",
  ],
  "compile_unsupported_type" => [
    "compile_unsupported_type.cr:6:11",
    "Unsupported type `Array(String)` for field 'tags'",
    "Remediation: declare `field tags : String`",
  ],
  "compile_non_literal_default" => [
    "compile_non_literal_default.cr:6:11",
    "Default `Time.utc.year` for field 'year : Int32' " \
    "is not a compile-time Int32 literal",
    "Remediation: write a literal default",
  ],
  "compile_missing_primary_key" => [
    "compile_missing_primary_key.cr:4:10",
    "Keyless has no primary key",
    "Remediation: add `field id : Int64, primary: true`",
  ],
}
sources = cases.keys.map { |name| "spec/fixtures/sugar_orm/#{name}.cr" }
results = Caramel::Checks.type_check(sources)
cases.each_with_index do |(name, required), index|
  result = results[index]
  output = "#{name}\n#{result.stdout}#{result.stderr}"
  Caramel::Checks.fail("#{name}\ncompiler timed out") if result.timed_out?
  if required
    Caramel::Checks.fail(output) if result.success?
    required.each do |text|
      next if result.stderr.includes?(text)
      Caramel::Checks.fail("missing #{text.inspect} in #{output}")
    end
  else
    Caramel::Checks.fail(output) unless result.success?
  end
  puts "PASS: #{name}"
end
