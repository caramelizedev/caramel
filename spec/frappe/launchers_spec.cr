require "spec"
require "file_utils"
require "../../src/frappe/launchers"

private def with_launcher_directory(& : String, String ->) : Nil
  base = File.tempname("caramel-launchers-spec-", dir: "/private/tmp")
  Dir.mkdir(base, 0o700)
  begin
    # A checkout path with a space and a quote, as a real one may have.
    root = File.join(base, "Bob's Caramel")
    Dir.mkdir_p(File.join(root, "bin"))
    %w[frappe latte].each do |name|
      binary = File.join(root, "bin", name)
      File.write(binary, "#!/bin/sh\nprintf '%s|' #{name} \"$@\"\n")
      File.chmod(binary, 0o755)
    end
    yield base, root
  ensure
    FileUtils.rm_rf(base)
  end
end

private def run_launcher(path : String, *args : String) : String
  output = IO::Memory.new
  Process.run(path, args.to_a, output: output).success?.should be_true
  output.to_s
end

describe Caramel::Frappe::Launchers do
  it "installs launchers that run the checkout's binaries with the caller's arguments" do
    with_launcher_directory do |base, root|
      launchers = Caramel::Frappe::Launchers.new(File.join(base, "home/.local/bin"))
      launchers.install(root)
      run_launcher(launchers.path("frappe"), "new", "two words").should eq("frappe|new|two words|")
      run_launcher(launchers.path("latte"), "daemon").should eq("latte|daemon|")
      (File.info(launchers.path("frappe")).permissions.value & 0o777).should eq(0o755)
    end
  end

  it "points its launchers at the newest installed release, not the one registered last" do
    with_launcher_directory do |base, root|
      launchers = Caramel::Frappe::Launchers.new(File.join(base, "bin"))
      registry = Caramel::Frappe::Installations.new(File.join(base, "state"))
      older = File.join(base, "older")
      registry.register("0.10.0", root)
      registry.register("0.9.0", older)
      launchers.follow(registry).should eq(root)
      run_launcher(launchers.path("frappe"), "doctor").should eq("frappe|doctor|")
      registry.remove("0.10.0")
      launchers.follow(registry, root).should eq(older)
      File.read(launchers.path("latte")).should contain("#{older}/bin/latte")
      registry.remove("0.9.0")
      launchers.follow(registry, older).should be_nil
      File.exists?(launchers.path("frappe")).should be_false
    end
  end

  it "refuses names taken by files it did not create, and writes neither launcher" do
    with_launcher_directory do |base, root|
      directory = File.join(base, "bin")
      Dir.mkdir(directory, 0o755)
      launchers = Caramel::Frappe::Launchers.new(directory)
      File.write(launchers.path("latte"), "#!/bin/sh\necho mine\n")
      taken = "#{launchers.path("latte")} exists and was not created by Caramel"
      expect_raises(Caramel::Frappe::Error, taken) do
        launchers.install(root)
      end
      File.read(launchers.path("latte")).should eq("#!/bin/sh\necho mine\n")
      File.exists?(launchers.path("frappe")).should be_false

      File.delete(launchers.path("latte"))
      File.symlink(File.join(root, "bin/latte"), launchers.path("latte"))
      expect_raises(Caramel::Frappe::Error, "was not created by Caramel") do
        launchers.install(root)
      end
      File.symlink?(launchers.path("latte")).should be_true
    end
  end

  it "refuses a directory other users can write" do
    with_launcher_directory do |base, root|
      directory = File.join(base, "shared")
      Dir.mkdir(directory)
      File.chmod(directory, 0o777)
      shared = "must be a directory you own that no one else can write"
      expect_raises(Caramel::Frappe::Error, shared) do
        Caramel::Frappe::Launchers.new(directory).install(root)
      end
      Dir.children(directory).should be_empty
    end
  end

  it "removes only the launchers that run the removed checkout" do
    with_launcher_directory do |base, root|
      launchers = Caramel::Frappe::Launchers.new(File.join(base, "bin"))
      launchers.install(root)
      launchers.remove(File.join(base, "other")).should be_empty
      launchers.remove(root).should eq([launchers.path("frappe"), launchers.path("latte")])
      Dir.children(launchers.directory).should be_empty
    end
  end
end
