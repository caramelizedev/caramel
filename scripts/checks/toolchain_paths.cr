require "./support/harness"

installed = File.realpath(Caramel::Checks.toolchain_root("Set CARAMEL_TOOLCHAIN_ROOT to the verified tool installation"))
root = Caramel::Checks.private_temp("Caramel's Toolchain $literal ")
begin
  Dir.mkdir(File.join(root, "data"))
  File.symlink(File.join(installed, "data/installs"), File.join(root, "data/installs"))
  File.symlink(File.join(installed, "bin"), File.join(root, "bin"))
  source = File.join(root, "path-check.cr")
  File.write(source, "require \"http/client\"\nputs \"native path check\"\n")
  binary = File.join(root, "check")
  env = {"CARAMEL_TOOLCHAIN_ROOT" => root} of String => String?
  result = Caramel::Checks.crystal(["build", source, "-o", binary], env: env, timeout: 90.seconds)
  raise result.stdout + result.stderr unless result.success?
  output = Caramel::Checks.run([binary], timeout: 5.seconds)
  raise output.stdout + output.stderr unless output.success? && output.stdout.strip == "native path check"
  loads = Caramel::Checks.run(["/usr/bin/otool", "-l", binary], timeout: 5.seconds)
  expected = File.join(root, "data/installs/conda-openssl/3.6.4/lib")
  raise loads.stdout + loads.stderr unless loads.success? && loads.stdout.includes?(expected)
ensure
  FileUtils.rm_rf(root)
end
puts "PASS: native build and execution with spaces, quote and dollar sign in toolchain prefix"
