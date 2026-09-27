require "./support/harness"

root = Caramel::Checks.private_temp("caramel-retirement-")
begin
  runner = File.join(root, "runner")
  build = Caramel::Checks.crystal(["build", "spec/fixtures/dev_retirement.cr", "-o", runner], timeout: 180.seconds)
  raise "Could not build retirement runner: #{build.stderr}" unless build.success?
  result = Caramel::Checks.run([runner, root], timeout: 20.seconds)
  raise "Retirement runner failed: #{result.stdout}#{result.stderr}" unless result.success?
  print result.stdout
  pid = File.read(File.join(root, "ready")).to_i64
  raise "TERM-resistant command survived retirement" unless Caramel::Checks.gone?(pid)
  puts "PASS: TERM-resistant command did not survive completed retirement"
ensure
  FileUtils.rm_rf(root)
end
