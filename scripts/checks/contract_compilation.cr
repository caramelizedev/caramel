require "./support/harness"

cases = {
  "compile_unsupported_type" => [
    "unsupported Caramel::RequestContract field type",
    "field tags : Hash(String, String)",
  ],
  "compile_array_without_max" => [
    "array fields must declare max:, the most items they accept: tags",
    "field tags : Array(String)",
  ],
  "compile_array_default" => [
    "array fields take no default; an absent array is empty: tags",
    "field tags : Array(String), max: 3, default: [] of String",
  ],
  "compile_array_of_files" => [
    "unsupported Caramel::RequestContract field type",
    "field tags : Array(Caramel::UploadedFile), max: 3",
  ],
  "compile_nested_array" => [
    "unsupported Caramel::RequestContract field type",
    "field tags : Array(Array(Int64)), max: 3",
  ],
  "compile_bounds_on_bool" => [
    "min/max apply only to String, Int32, Int64 and Float64 fields",
    "field active : Bool, min: 1",
  ],
  "compile_unknown_access"   => ["undefined method 'admin'"],
  "compile_field_value_wire" => [
    "Grams includes Caramel::FieldValue(Float32), but a field value binds from String, " \
    "Int32, Int64, Float64, Bool or Time: weight",
    "field weight : Grams",
  ],
  "compile_field_value_without_from_field" => [
    "Grams includes Caramel::FieldValue(Int32) but defines no " \
    "self.from_field(raw : Int32, & : String ->): weight",
    "field weight : Grams",
  ],
  "compile_field_value_bounds" => [
    "min/max apply only to String, Int32, Int64 and Float64 fields: count",
    "field count : EvenCount, min: 2",
  ],
  "compile_array_field_value_wire" => [
    "Grams includes Caramel::FieldValue(Float32), but a field value binds from String, " \
    "Int32, Int64, Float64, Bool or Time: weights",
    "field weights : Array(Grams), max: 3",
  ],
  "compile_array_field_value_without_from_field" => [
    "Grams includes Caramel::FieldValue(Int32) but defines no " \
    "self.from_field(raw : Int32, & : String ->): weights",
    "field weights : Array(Grams), max: 3",
  ],
  # The negative control: a type that only defines from_field is not a field value.
  "compile_duck_typed_value" => [
    "unsupported Caramel::RequestContract field type: Grams",
    "field weight : Grams",
  ],
}
sources = cases.keys.map { |name| "spec/fixtures/contracts/#{name}.cr" }
results = Caramel::Checks.type_check(sources)
cases.each_with_index do |(name, required), index|
  result = results[index]
  output = "#{name}\n#{result.stdout}#{result.stderr}"
  Caramel::Checks.fail(output) if result.success?
  Caramel::Checks.fail("#{name}\ncompiler timed out") if result.timed_out?
  required.each do |text|
    next if result.stderr.includes?(text)
    Caramel::Checks.fail("missing #{text.inspect} in #{output}")
  end
  puts "PASS: #{name}"
end
