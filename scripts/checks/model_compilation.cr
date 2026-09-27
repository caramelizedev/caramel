require "./support/harness"

cases = {
  "compile_valid" => nil,
  "compile_unknown_field" => "unknown Caramel::Model query field",
  "compile_wrong_value" => "expected argument #1",
  "compile_unknown_order" => "unknown Caramel::Model order field",
  "compile_unknown_constructor" => "unknown or system-managed Caramel::Model constructor field",
  "compile_system_constructor" => "unknown or system-managed Caramel::Model constructor field",
  "compile_primary_mutation" => "undefined method 'id='",
  "compile_unsupported_type" => "unsupported Caramel::Model field type",
  "compile_unknown_option" => "unknown Caramel::Model field option",
  "compile_unknown_validation" => "unknown Caramel::Model validation option",
}
cases.each do |name, error|
  result = Caramel::Checks.crystal(["build", "spec/fixtures/models/#{name}.cr", "--no-codegen"], timeout: 90.seconds)
  output = result.stdout + result.stderr
  Caramel::Checks.fail("#{name}\ncompiler timed out") if result.timed_out
  if error
    Caramel::Checks.fail("#{name}\n#{output}") if result.success? || !result.stderr.includes?(error)
  else
    Caramel::Checks.fail(output) unless result.success?
  end
  puts "PASS: #{name}"
end
