require "./support/harness"

result = Caramel::Checks.crystal(["build", "--no-codegen", "spec/fixtures/views/unknown_local_compile.cr"], timeout: 1.hour)
output = result.stdout + result.stderr
unless !result.success? && {"unknown_local.html.ecr:1:8", "undefined local variable or method 'missing_local'"}.all? { |text| output.includes?(text) }
  STDERR.print output
  Caramel::Checks.fail("Template diagnostic did not identify the original expression at line 1, column 8")
end
puts "Typed template compile-failure and source-location check: passed"

result = Caramel::Checks.crystal(["build", "--no-codegen", "spec/fixtures/views/compile_view_outside_app.cr"], timeout: 1.hour)
output = result.stdout + result.stderr
unless !result.success? && output.includes?("view must be called from a file under app/actions")
  STDERR.print output
  Caramel::Checks.fail("Conventional view lookup outside app/actions was not refused")
end
puts "Conventional view lookup refusal outside app/actions: passed"
