require "./support/harness"

installed = File.realpath(Caramel::Checks.toolchain_root)
root = Caramel::Checks.private_temp("Caramel's Toolchain $literal ")
begin
  Dir.mkdir(File.join(root, "data"))
  File.symlink(File.join(installed, "data/installs"), File.join(root, "data/installs"))
  File.symlink(File.join(installed, "bin"), File.join(root, "bin"))
  source = File.join(root, "path-check.cr")
  File.write(source, "require \"http/client\"\nrequire \"big\"\n" \
                     "puts \"native path check \#{BigDecimal.new(\"0.1\") + " \
                     "BigDecimal.new(\"0.2\")}\"\n")
  binary = File.join(root, "check")
  env = {"CARAMEL_TOOLCHAIN_ROOT" => root} of String => String?
  result = Caramel::Checks.crystal(["build", source, "-o", binary], env: env, timeout: 90.seconds)
  raise result.stdout + result.stderr unless result.success?
  output = Caramel::Checks.run([binary], timeout: 5.seconds)
  printed = output.success? && output.stdout.strip == "native path check 0.3"
  raise output.stdout + output.stderr unless printed
  loads = Caramel::Checks.run(["/usr/bin/otool", "-l", binary], timeout: 5.seconds)
  expected = File.join(root, "data/installs/conda-openssl/3.6.4/lib")
  raise loads.stdout + loads.stderr unless loads.success? && loads.stdout.includes?(expected)
  gmp = File.join(root, "data/installs/conda-gmp/6.3.0/lib")
  raise loads.stdout + loads.stderr unless loads.stdout.includes?(gmp)
ensure
  FileUtils.rm_rf(root)
end
puts "PASS: native build and execution, with OpenSSL and GMP, " \
     "with spaces, quote and dollar sign in toolchain prefix"
