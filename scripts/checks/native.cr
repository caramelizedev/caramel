require "./support/harness"

["scripts/build-latte-menu", "scripts/build-latte-relay", "scripts/build-installers"].each do |builder|
  result = Caramel::Checks.run([File.join(Caramel::Checks::REPO, builder)], timeout: 300.seconds)
  STDOUT.print result.stdout
  STDERR.print result.stderr
  exit result.status.exit_code unless result.success?
end
result = Caramel::Checks.run([File.join(Caramel::Checks::REPO, "scripts/build-installers"), "--test"], timeout: 300.seconds)
STDOUT.print result.stdout
STDERR.print result.stderr
exit result.status.exit_code unless result.success?

result = Caramel::Checks.crystal(["spec", "spec/native", "--error-trace"], timeout: 300.seconds)
STDOUT.print result.stdout
STDERR.print result.stderr
exit result.status.exit_code unless result.success?
