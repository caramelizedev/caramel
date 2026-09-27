require "./support/harness"

repo = Caramel::Checks::REPO
{"puts 1", %(require "http"; puts 1)}.each do |source|
  result = Caramel::Checks.crystal(["eval", source], timeout: 1.hour)
  unless result.success? && result.stdout.strip == "1"
    STDERR.print result.stdout, result.stderr
    Caramel::Checks.fail("Managed Crystal eval regression")
  end
end
puts "Managed Crystal eval and OpenSSL loading: passed"
