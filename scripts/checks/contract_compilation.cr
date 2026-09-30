require "./support/harness"

cases = {
  "compile_unsupported_type" => [
    "unsupported Caramel::RequestContract field type",
    "field tags : Array(String)",
  ],
  "compile_bounds_on_bool" => [
    "min/max apply only to String, Int32, Int64 and Float64 fields",
    "field active : Bool, min: 1",
  ],
  "compile_unknown_access" => ["undefined method 'admin'"],
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
