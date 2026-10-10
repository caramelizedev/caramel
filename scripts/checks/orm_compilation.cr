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
    "Remediation: declare `field tags : String` (or another supported type), " \
    "or store the type through a codec: `field tags : Array(String), codec: SomeCodec`.",
  ],
  "compile_codec_default" => [
    "compile_codec_default.cr:20:11",
    "Field 'price' has codec: PlainCodec, so it takes no default.",
    "Remediation: set the value in a changeset.",
  ],
  "compile_codec_where_range" => [
    "compile_codec_where_range.cr:24:15",
    "no overload matches 'Priced::QueryOf(NamedTuple()).where', price: Range(Int32, Int32)",
    "price : ::Priced::SugarTypePrice | ::SugarORM::Unset",
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
  "compile_duplicate_table" => [
    "compile_duplicate_table.cr:10:10",
    "Blend declares the table \"teas\", which Tea already declares.",
    "Remediation: give one of them another table name",
  ],
  "compile_check_shape" => [
    "compile_check_shape.cr:7:",
    "check expects column ranges or one named SQL expression, " \
    "like `check stock: 0..`, `check quantity: 1..10` " \
    "or `check :dates, \"starts_at < ends_at\"`.",
  ],
  "compile_check_range" => [
    "compile_check_range.cr:7:",
    "check seats: takes an inclusive range of integer literals, like `0..`, `..10` or `1..10`.",
  ],
  "compile_check_empty" => [
    "compile_check_empty.cr:7:",
    "check seats: 10..1 is empty.",
    "Remediation: put the lower bound first.",
  ],
  "compile_check_field_type" => [
    "compile_check_field_type.cr:7:",
    "check name: needs an Int32 or Int64 field, but 'name' is String.",
    "Remediation: use a named SQL expression, like `check :name_rule, \"…\"`.",
  ],
  "compile_check_unknown_column" => [
    "compile_check_unknown_column.cr:7:",
    "check references 'beds', which is not a column of Room.",
    "Columns: id, seats",
  ],
  "compile_check_duplicate" => [
    "compile_check_duplicate.cr:8:",
    "Room declares the check check_rooms_seats twice.",
    "Remediation: give each check its own name; a range check is named after its column.",
  ],
  "compile_check_semicolon" => [
    "compile_check_semicolon.cr:7:",
    "check :limit: takes one SQL expression without ';'.",
  ],
  "compile_check_name_too_long" => [
    "compile_check_name_too_long.cr:7:",
    "The check name check_conference_room_reservations_maximum_attendees_allowed_per_window " \
    "is longer than PostgreSQL's 63-byte limit.",
    "Remediation: shorten the check's name or the table name.",
  ],
  "compile_version_type" => [
    "compile_version_type.cr:6:",
    "The version field 'lock_version' must be a non-nilable Int32 or Int64 " \
    "without a default; it starts at 0.",
    "Remediation: declare `field lock_version : Int32, version: true`.",
  ],
  "compile_version_default" => [
    "compile_version_default.cr:6:",
    "The version field 'lock_version' must be a non-nilable Int32 or Int64 " \
    "without a default; it starts at 0.",
  ],
  "compile_version_twice" => [
    "compile_version_twice.cr:7:",
    "Counter already has the version field 'lock_version'.",
    "Remediation: keep a single `version: true` field.",
  ],
  "compile_upsert_shape" => [
    "compile_upsert_shape.cr:5:",
    "upsert expects `upsert on: :column`, or `upsert on: [:a, :b]` " \
    "for a multi-column unique index, optionally with `update: [:field, …]`.",
  ],
  "compile_upsert_unknown_index" => [
    "compile_upsert_unknown_index.cr:5:",
    "Team has no unique index on seats.",
    "Unique indexes: name",
    "Remediation: add `index :seats, unique: true` to Team's schema block",
  ],
  "compile_upsert_update_target" => [
    "compile_upsert_update_target.cr:5:",
    "upsert cannot update 'name', which its conflict target matches.",
    "Remediation: remove :name from update:.",
  ],
  "compile_upsert_update_version" => [
    "compile_upsert_update_version.cr:15:",
    "upsert cannot update 'lock_version', Sale's version field; an upsert increments it.",
    "Remediation: remove :lock_version from update:.",
  ],
  "compile_upsert_not_param" => [
    "compile_upsert_not_param.cr:5:",
    "upsert names 'seats', which is not a param of Team::Upsert.",
    "Remediation: add `param seats : Int32` to Team::Upsert.",
  ],
  "compile_upsert_twice" => [
    "compile_upsert_twice.cr:6:",
    "Team::Upsert declares upsert twice.",
    "Remediation: keep one `upsert`.",
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
