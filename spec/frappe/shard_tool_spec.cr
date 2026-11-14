require "spec"
require "file_utils"
require "../../src/frappe/shard_tool"

private alias ShardTool = Caramel::Frappe::ShardTool

private ENTRY = "src/demo/frappe.cr"
private GIT   = {"git" => "https://example.test/demo.git", "version" => "0.1.0"}

# A directory of this spec's own, removed afterwards.
private def workspace(&)
  root = File.tempname("caramel-shard-tool-", dir: "/private/tmp")
  Dir.mkdir(root, 0o700)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

# A project *name* under *workspace* whose shard.lock says *locked* of the demo shard.
private def project(workspace : String, name : String, locked : Hash(String, String)) : String
  root = File.join(workspace, name)
  Dir.mkdir_p(File.join(root, "lib"))
  framework = {"path" => "../caramel", "version" => Caramel::VERSION}
  lock = {"version" => 2.0, "shards" => {"caramel" => framework, "demo" => locked}}
  File.write(File.join(root, "shard.lock"), lock.to_yaml)
  root
end

# A checkout *name* under *workspace* with one source file, as a path dependency has.
private def checkout(workspace : String, name : String, source : String) : String
  root = File.join(workspace, name)
  Dir.mkdir_p(File.join(root, "src"))
  File.write(File.join(root, "src/#{name}.cr"), source)
  root
end

# The project *name* whose demo shard is the path dependency *checkout*, at *path* in
# its shard.lock.
private def path_project(workspace : String, name : String, checkout : String,
                         path : String) : String
  root = project(workspace, name, {"path" => path, "version" => "0.1.0"})
  File.symlink(checkout, File.join(root, "lib/demo"))
  root
end

private def fingerprint(root : String, entry : String = ENTRY) : String
  ShardTool.fingerprint(root, "demo", entry)
end

# A finished build waiting to be installed: a binary and its debug file.
private def finished(directory : String, content : String) : String
  Dir.mkdir_p(directory)
  temporary = File.join(directory, "building")
  File.write(temporary, content)
  File.write(temporary + ".dwarf", "debug information for #{content}")
  temporary
end

describe Caramel::Frappe::ShardTool do
  it "gives one shard at one version the same key in every project" do
    workspace do |space|
      first = project(space, "first", GIT)
      second = project(space, "second", GIT)
      fingerprint(first).should eq(fingerprint(second))
      kept = "/toolchain/shard-tools/demo-0.1.0"
      ShardTool.directory("/toolchain", first, "demo").should eq(kept)
      ShardTool.directory("/toolchain", second, "demo").should eq(kept)
    end
  end

  it "keys a build by the shard's version, commit and source, and by its entry file" do
    workspace do |space|
      released = fingerprint(project(space, "released", GIT))
      newer = project(space, "newer", GIT.merge({"version" => "0.2.0"}))
      fingerprint(newer).should_not eq(released)
      commit = project(space, "commit", GIT.merge({"version" => "0.1.0+git.commit.4f2a"}))
      fingerprint(commit).should_not eq(released)
      ShardTool.directory("/toolchain", commit, "demo")
        .should eq("/toolchain/shard-tools/demo-0.1.0+git.commit.4f2a")
      fork = project(space, "fork", GIT.merge({"git" => "https://example.test/fork.git"}))
      fingerprint(fork).should_not eq(released)
      fingerprint(fork, "src/demo/other.cr").should_not eq(fingerprint(fork))
    end
  end

  it "keys a path dependency by its sources, wherever a project's lock says it is" do
    workspace do |space|
      demo = checkout(space, "demo", "module Demo; end\n")
      near = path_project(space, "near", demo, "../demo")
      far = path_project(space, "far", demo, "../../elsewhere/demo")
      before = fingerprint(near)
      fingerprint(far).should eq(before)
      File.write(File.join(demo, "README.md"), "Not a source.\n")
      fingerprint(near).should eq(before)
      File.write(File.join(demo, "src/demo.cr"), "module Demo; VERSION = 2; end\n")
      fingerprint(near).should_not eq(before)
      fingerprint(far).should eq(fingerprint(near))
    end
  end

  it "builds again when a framework that is a path dependency changes" do
    workspace do |space|
      framework = checkout(space, "caramel", "module Caramel; end\n")
      root = project(space, "app", GIT)
      released = fingerprint(root)
      File.symlink(framework, File.join(root, "lib/caramel"))
      linked = fingerprint(root)
      linked.should_not eq(released)
      File.write(File.join(framework, "src/caramel.cr"), "module Caramel; EDITED = 1; end\n")
      fingerprint(root).should_not eq(linked)
    end
  end

  it "reuses in a second project the build the first one left in the toolchain" do
    workspace do |space|
      toolchain = File.join(space, "toolchain")
      first = project(space, "first", GIT)
      second = project(space, "second", GIT)
      built = ShardTool.slot(toolchain, first, "demo")
      built.binary.should eq(File.join(toolchain, "shard-tools/demo-0.1.0/tool"))
      built.install(finished(File.dirname(built.binary), "the tool"), fingerprint(first))
      ShardTool.slot(toolchain, second, "demo").holds?(fingerprint(second)).should be_true
      newer = project(space, "newer", GIT.merge({"version" => "0.2.0"}))
      ShardTool.slot(toolchain, newer, "demo").holds?(fingerprint(newer)).should be_false
      other = File.join(space, "other-toolchain")
      ShardTool.slot(other, second, "demo").holds?(fingerprint(second)).should be_false
    end
  end

  it "serializes the builds of one program across the projects that share it" do
    workspace do |space|
      directory = File.join(space, "toolchain/shard-tools/demo-0.1.0")
      holder = Caramel::Frappe::BuildLock.new(directory)
      waiter = Caramel::Frappe::BuildLock.new(directory)
      holder.acquire?.should be_true
      waiter.acquire?.should be_false
      holder.release
      waiter.acquire?.should be_true
      waiter.release
    end
  end
end
