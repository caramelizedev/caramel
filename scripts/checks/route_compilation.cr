require "./support/harness"

cases = {
  "compile_valid"                  => nil,
  "compile_missing_contract_field" => {[
    "ROUTE CONTRACT MISMATCH", "is missing 'field team_id : Type'", "compile_missing_contract_field.cr:",
    "Contract: #{Caramel::Checks::REPO}/spec/fixtures/routes/compile_missing_contract_field.cr:5:5\n",
    "Remediation: add `field team_id : Int64` to the contract block of TeamShow.",
  ], [] of String},
  "compile_wrong_param_type" => {["ROUTE CONTRACT TYPE MISMATCH", "compile_wrong_param_type.cr:", "Contract: #{Caramel::Checks::REPO}/spec/fixtures/routes/compile_wrong_param_type.cr:5:5\n", "Remediation: declare `field team_id : Int64`"], [] of String},
  "compile_nilable_param"    => {["ROUTE CONTRACT TYPE MISMATCH", "team_id : Int64?", "Remediation:"], [] of String},
  "compile_defaulted_param"  => {["ROUTE CONTRACT TYPE MISMATCH", "without defaults", "Remediation:"], [] of String},
  "compile_undefined_action" => {["Action 'Missing::Show' is undefined", "compile_undefined_action.cr:"], [] of String},
  "compile_not_action"       => {["must inherit from Caramel::Action", "Remediation:"], [] of String},
  "compile_missing_contract" => {["must define an explicit `contract do ... end` block", "Remediation:"], [] of String},
  "compile_duplicate_route"  => {["DUPLICATE ROUTE", %(get "/teams/:id", TeamOther)], ["__caramel_router_draw"]},
  "compile_ambiguous_order"  => {["AMBIGUOUS ROUTE ORDER", %(get "/teams/new", TeamNew)], ["__caramel_router_draw"]},
  "compile_unknown_verb"     => {["accepts only get, post, put, patch and delete", "resources :books"], ["__caramel_router_draw"]},
  "compile_wrong_path_id"    => {["expected argument #1"], [] of String},
}
cases.each do |name, expectation|
  result = Caramel::Checks.crystal(["build", "spec/fixtures/routes/#{name}.cr", "--no-codegen"], timeout: 90.seconds)
  output = "#{name}\n#{result.stdout}#{result.stderr}"
  Caramel::Checks.fail("#{name}\ncompiler timed out") if result.timed_out?
  if expectation
    required, forbidden = expectation
    Caramel::Checks.fail(output) if result.success?
    required.each { |text| Caramel::Checks.fail("missing #{text.inspect} in #{output}") unless result.stderr.includes?(text) }
    forbidden.each { |text| Caramel::Checks.fail("unexpected #{text.inspect} in #{output}") if result.stderr.includes?(text) }
  else
    Caramel::Checks.fail(output) unless result.success?
  end
  puts "PASS: #{name}"
end
