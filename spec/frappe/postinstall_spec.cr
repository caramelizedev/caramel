require "spec"
require "file_utils"
require "../../src/frappe/postinstall"

# A project whose lib/ holds one installed dependency, `parser`, whose
# postinstall writes ext/built with the count of runs so far.
private def postinstall_project(root : String, script : String) : String
  project = File.join(root, "app")
  parser = File.join(project, "lib/parser")
  Dir.mkdir_p(File.join(parser, "src"))
  File.write(File.join(project, "lib/.shards.info"), postinstall_info("parser", "1.2.3"))
  File.write(File.join(parser, "shard.yml"),
    "name: parser\nversion: 1.2.3\nscripts:\n  postinstall: #{script}\n")
  File.write(File.join(parser, "src/parser.cr"), "# source\n")
  project
end

# Shards' record of one installed dependency.
private def postinstall_info(name : String, version : String) : String
  "version: 1.0\nshards:\n  #{name}:\n    git: https://example.invalid/#{name}.git\n" \
  "    version: #{version}\n"
end

private def postinstall_run(root : String, project : String, output : IO) : Array(String)
  runs = [] of String
  cache = File.join(root, "toolchain")
  Caramel::Frappe::Postinstall.new("/nonexistent", cache, output) do |script, directory, _env|
    runs << script
    Process.run("/bin/sh", ["-c", script], chdir: directory)
  end.run(project)
  runs
end

describe Caramel::Frappe::Postinstall do
  it "runs a dependency's postinstall once per version, then copies what it wrote" do
    root = File.tempname("caramel-postinstall-")
    Dir.mkdir(root)
    begin
      script = "mkdir -p ext && echo run >> ext/built"
      first = postinstall_project(File.join(root, "1"), script)
      output = IO::Memory.new
      postinstall_run(root, first, output).should eq([script])
      File.read(File.join(first, "lib/parser/ext/built")).should eq("run\n")
      output.to_s.should contain("I: Postinstall of parser: #{script}")
      cache = File.join(root, "toolchain/postinstall-cache/parser-1.2.3")
      File.read(File.join(cache, "ext/built")).should eq("run\n")
      File.exists?(File.join(cache, "src/parser.cr")).should be_false

      second = postinstall_project(File.join(root, "2"), script)
      output = IO::Memory.new
      postinstall_run(root, second, output).should be_empty
      File.read(File.join(second, "lib/parser/ext/built")).should eq("run\n")
      output.to_s.should contain("I: Postinstall of parser: kept from the toolchain")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "runs the script again when the dependency changed it, and skips dependencies without one" do
    root = File.tempname("caramel-postinstall-")
    Dir.mkdir(root)
    begin
      first = postinstall_project(File.join(root, "1"), "mkdir -p ext && echo one > ext/built")
      postinstall_run(root, first, IO::Memory.new).size.should eq(1)
      changed = "mkdir -p ext && echo two > ext/built"
      second = postinstall_project(File.join(root, "2"), changed)
      postinstall_run(root, second, IO::Memory.new).should eq([changed])
      File.read(File.join(second, "lib/parser/ext/built")).should eq("two\n")

      plain = File.join(root, "3/app")
      Dir.mkdir_p(File.join(plain, "lib/plain"))
      File.write(File.join(plain, "lib/.shards.info"), postinstall_info("plain", "0.1.0"))
      File.write(File.join(plain, "lib/plain/shard.yml"), "name: plain\nversion: 0.1.0\n")
      postinstall_run(root, plain, IO::Memory.new).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
