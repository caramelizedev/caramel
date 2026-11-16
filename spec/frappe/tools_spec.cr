require "spec"
require "file_utils"
require "../../src/frappe/tools"

private ENVIRONMENT = <<-YAML
  version: 1
  name: bookshelf
  postgresql_major: 18
  extensions: []
  domain_suffix: test
  YAML

private DATABASE = "postgres://bookshelf@localhost/bookshelf_development"

# Stands in for a built application: it lists the commands it registers; any other
# command records that it ran, then greets the line it reads from standard input.
private APPLICATION = <<-'SH'
  #!/bin/sh
  if [ "$1" = commands ]; then
    printf 'demo:greet\ndemo:notes\n'
    exit 0
  fi
  echo "$*" > ran
  echo ready
  read name
  echo "Hello, $name, from $DATABASE_URL in $CARAMEL_ENV"
  exit 3
  SH

# An application that cannot say what it registers.
private BROKEN = <<-SH
  #!/bin/sh
  echo "It does not start" >&2
  exit 1
  SH

# Yields a set-up project, which is its own checkout with a toolchain, and the built
# application *script* stands in for; removes them afterwards.
private def application(script : String = APPLICATION, &)
  root = File.tempname("caramel-tools-", dir: "/private/tmp")
  Dir.mkdir(root, 0o700)
  toolchain = File.join(root, "toolchain")
  Dir.mkdir(toolchain, 0o700)
  File.write(File.join(root, ".caramel-toolchain"), toolchain)
  File.write(File.join(root, ".env"), "DATABASE_URL=#{DATABASE.inspect}\n", perm: 0o600)
  binary = File.join(root, "application")
  File.write(binary, script + "\n", perm: 0o700)
  metadata = Caramel::Frappe::EnvironmentManifest.from_yaml(ENVIRONMENT)
  yield Caramel::Frappe::Project.new(root, metadata), binary
ensure
  FileUtils.rm_rf(root) if root
end

private def tools(project : Caramel::Frappe::Project,
                  output : IO = IO::Memory.new,
                  error : IO = IO::Memory.new) : Caramel::Frappe::Tools
  Caramel::Frappe::Tools.new(project.root, output, error)
end

# Stands in for scripts/shards: it records its arguments.
private LAUNCHER = <<-SH
  #!/bin/sh
  echo "$*" > installed

  SH

private MANIFEST = <<-YAML
  name: bookshelf
  version: 0.1.0
  dependencies:
    caramel:
      path: ../caramel
    sweettalk:
      github: example/sweettalk
  development_dependencies:
    lexbor:
      github: example/lexbor

  YAML

# A lock of each of *names*.
private def lock(names : Array(String)) : String
  entries = names.map { |name| "  #{name}:\n    path: ../#{name}\n    version: 0.1.0\n" }
  "version: 2.0\nshards:\n#{entries.join('\n')}"
end

# Yields a project that names caramel, sweettalk and lexbor and locks *locked*, in a
# checkout whose scripts/shards is LAUNCHER.
private def dependent(locked : Array(String), &)
  application do |project, _|
    Dir.mkdir(File.join(project.root, "scripts"))
    File.write(File.join(project.root, "scripts/shards"), LAUNCHER, perm: 0o700)
    File.write(File.join(project.root, "shard.yml"), MANIFEST)
    File.write(File.join(project.root, "shard.lock"), lock(locked))
    yield project
  end
end

describe Caramel::Frappe::Tools do
  it "runs a contributed command with its output as written and its standard input" do
    application do |project, binary|
      reader, writer = IO.pipe
      input, feed = IO.pipe
      finished = Channel(Int32?).new
      runner = tools(project, writer)
      spawn do
        status = runner.contributed(project, binary, ["demo:greet", "--loud"], input)
      ensure
        writer.close
        finished.send(status)
      end
      # The first line arrives while the command still waits for its input.
      reader.gets.should eq("ready")
      feed.puts("Ada")
      feed.close
      reader.gets.should eq("Hello, Ada, from #{DATABASE} in development")
      finished.receive.should eq(3)
      File.read(File.join(project.root, "ran")).should eq("demo:greet --loud\n")
    end
  end

  it "installs what shard.lock holds when it locks every dependency shard.yml names" do
    dependent(%w[caramel sweettalk lexbor pg]) do |project|
      tools(project).dependencies(project)
      installed = File.read(File.join(project.root, "installed"))
      installed.should eq("install --frozen --skip-postinstall\n")
    end
  end

  it "refuses a dependency shard.yml names and shard.lock lacks, naming frappe shards " \
     "install, before Shards runs" do
    dependent(%w[caramel]) do |project|
      remedy = "shard.lock does not lock sweettalk, lexbor, which shard.yml names; run " \
               "frappe shards install to lock and install what was added, then frappe setup"
      expect_raises(Caramel::Frappe::Error, remedy) { tools(project).dependencies(project) }
      File.exists?(File.join(project.root, "installed")).should be_false
    end
  end

  it "runs a contributed command with the project's local environment" do
    application do |project, binary|
      output = IO::Memory.new
      input = IO::Memory.new("Grace\n")
      tools(project, output).contributed(project, binary, ["demo:notes", "list"], input)
      output.to_s.should eq("ready\nHello, Grace, from #{DATABASE} in development\n")
    end
  end

  it "answers nil for a command the application does not register, without running it" do
    application do |project, binary|
      output = IO::Memory.new
      tools(project, output).contributed(project, binary, ["demo:absent", "now"]).should be_nil
      File.exists?(File.join(project.root, "ran")).should be_false
      output.to_s.should eq("")
    end
  end

  it "asks the application which commands it registers" do
    application do |project, binary|
      none = {} of String => String
      names = tools(project).registered(binary, project.root, none)
      names.should eq(["demo:greet", "demo:notes"])
    end
  end

  it "refuses an application that does not list its commands, beside what it said" do
    application(BROKEN) do |project, binary|
      errors = IO::Memory.new
      message = "The application did not list its commands; see the diagnostic above"
      expect_raises(Caramel::Frappe::Error, message) do
        tools(project, IO::Memory.new, errors).contributed(project, binary, ["demo:greet"])
      end
      errors.to_s.should eq("It does not start\n")
    end
  end

  it "refuses to run a contributed command in a project that is not set up" do
    application do |project, binary|
      File.delete(File.join(project.root, ".env"))
      message = "Local configuration is missing; run frappe setup"
      expect_raises(Caramel::Frappe::Error, message) do
        tools(project).contributed(project, binary, ["demo:greet"])
      end
    end
  end
end
