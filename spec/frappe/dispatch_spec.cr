require "spec"
require "file_utils"
require "../../src/frappe/dispatch"

private def pin(project : String, version : String) : Nil
  lock = <<-YAML
    version: 2.0
    shards:
      caramel:
        git: https://github.com/caramelizedev/caramel.git
        version: #{version}\n
    YAML
  File.write(File.join(project, "shard.lock"), lock)
end

describe Caramel::Frappe::Dispatch do
  it "dispatches only pinned project commands to a registered executable" do
    root = "/private/tmp/caramel-dispatch-spec-#{Random::Secure.hex(8)}"
    Dir.mkdir(root, 0o700)
    project = File.join(root, "app")
    Dir.mkdir(project, 0o700)
    state = File.join(root, "state")
    env = {"CARAMEL_HOME" => state}
    pin(project, Caramel::VERSION)
    Caramel::Frappe::Dispatch.target(["routes"], project, env).should be_nil
    pin(project, "9.9.9")
    expect_raises(Caramel::Frappe::Error, "no Caramel installation is registered") do
      Caramel::Frappe::Dispatch.target(["routes"], project, env)
    end
    binary = File.join(root, "fake/bin/frappe")
    FileUtils.mkdir_p(File.dirname(binary))
    File.write(binary, "#!/bin/sh\nexit 0\n")
    File.chmod(binary, 0o755)
    Caramel::Frappe::Installations.new(state).register("9.9.9", File.dirname(File.dirname(binary)))
    Caramel::Frappe::Dispatch.target(["routes"], project, env).should eq(binary)
    # A commit pin names its release without the build metadata.
    pin(project, "9.9.9+git.commit.0123456789abcdef")
    Caramel::Frappe::Dispatch.target(["routes"], project, env).should eq(binary)
    dispatched = env.merge({"CARAMEL_FRAPPE_DISPATCHED" => "1"})
    Caramel::Frappe::Dispatch.target(["routes"], project, dispatched).should be_nil
    %w[new sites installations services agent-manifest help].each do |command|
      Caramel::Frappe::Dispatch.target([command], project, env).should be_nil
    end
    Caramel::Frappe::Dispatch.target(["lsp", "install"], project, env).should be_nil
    # Project commands, including malformed ones, run under the pinned release,
    # which validates them with its own command table.
    project_commands = [
      ["check", "--agent"], ["corretto"], ["expand", "x"],
      ["db", "branch", "create", "x"], ["db", "bogus"], ["lsp", "crystalline"],
    ]
    project_commands.each do |arguments|
      Caramel::Frappe::Dispatch.target(arguments, project, env).should eq(binary)
    end
    pin(project, "not-a-release")
    Caramel::Frappe::Dispatch.target(["routes"], project, env).should be_nil
    pin(project, "9.9.9")
    File.delete(binary)
    expect_raises(Caramel::Frappe::Error, "has no executable") do
      Caramel::Frappe::Dispatch.target(["routes"], project, env)
    end
  ensure
    FileUtils.rm_rf(root) if root
  end
end
