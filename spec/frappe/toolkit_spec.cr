require "spec"
require "file_utils"
require "../../src/frappe/toolkit"

private alias Toolkit = Caramel::Frappe::Toolkit

private CONFIG = <<-CRYSTAL
  require "caramel"
  require "caramel/crema/recorder"

  module App
  end

  CRYSTAL

# Yields the root of a project that holds config/application.cr; removes it afterwards.
private def project(&)
  root = File.tempname("caramel-toolkit-", dir: "/private/tmp")
  Dir.mkdir_p(File.join(root, "config"), 0o700)
  File.write(File.join(root, Toolkit::CONFIG), CONFIG)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

# Every file under *root* outside .caramel, with its content.
private def files(root : String) : Hash(String, String)
  paths = Dir.glob(File.join(root, "**/*")).select { |path| File.file?(path) }
  paths.to_h { |path| {path.lchop(root + "/"), File.read(path)} }
end

# What *block* prints.
private def printed(& : IO ->) : String
  String.build { |io| yield io }
end

describe Caramel::Frappe::Toolkit do
  it "tells a tool program the project's root and who reads its output" do
    agent = Toolkit.environment("/projects/bookshelf", agent: true, color: false)
    agent.should eq({
      "CARAMEL_PROJECT_ROOT" => "/projects/bookshelf",
      "CARAMEL_DIAGNOSTICS"  => "mrdp",
      "NO_COLOR"             => "1",
    })
    Toolkit.root(agent).should eq("/projects/bookshelf")
    Toolkit.agent?(agent).should be_true
    plain = Toolkit.environment("/projects/bookshelf", agent: false, color: false)
    plain.should eq({"CARAMEL_PROJECT_ROOT" => "/projects/bookshelf", "NO_COLOR" => "1"})
    Toolkit.agent?(plain).should be_false
    colored = Toolkit.environment("/projects/bookshelf", agent: false, color: true)
    colored.should eq({"CARAMEL_PROJECT_ROOT" => "/projects/bookshelf"})
  end

  it "takes the current directory for the root when Frappé names none" do
    Toolkit.root({} of String => String).should eq(Dir.current)
    Toolkit.agent?({} of String => String).should be_false
  end

  it "colours nothing for an agent, without a terminal or when told not to" do
    none = {} of String => String
    Toolkit.color?(IO::Memory.new, none).should be_false
    Toolkit.color?(IO::Memory.new, {"CARAMEL_DIAGNOSTICS" => "mrdp"}).should be_false
    Toolkit.color?(IO::Memory.new, {"NO_COLOR" => "1"}).should be_false
  end

  it "prints a Generated line for each file" do
    lines = printed { |io| Toolkit.generated(io, ["config/demo.cr", "config/application.cr"]) }
    lines.should eq("Generated config/demo.cr\nGenerated config/application.cr\n")
  end

  it "closes an agent's success with MRDP's OK line" do
    line = printed { |io| Caramel::Frappe::MRDP.ok(io, "demo:install", "2 files") }
    line.should eq("OK demo:install 2 files\n")
  end

  it "prints a failure as its message and fix for a person" do
    lines = printed do |io|
      Toolkit.failed(io, "demo:install", "File already exists: config/demo.cr",
        agent: false, fix: "Remove it first.")
    end
    lines.should eq("File already exists: config/demo.cr\nRemove it first.\n")
    bare = printed { |io| Toolkit.failed(io, "demo:install", "No such note", agent: false) }
    bare.should eq("No such note\n")
  end

  it "prints a failure as an MRDP diagnostic for an agent" do
    lines = printed do |io|
      Toolkit.failed(io, "demo:install", "File already exists: config/demo.cr",
        agent: true, fix: "Remove it first.")
    end
    lines.should eq(<<-MRDP)
      ERR USAGE at frappe demo:install
      MSG: File already exists: config/demo.cr
      FIX: Remove it first.\n
      MRDP
    coded = printed do |io|
      Toolkit.failed(io, "demo:install", "It broke", agent: true, code: "RUNTIME")
    end
    coded.should eq("ERR RUNTIME at frappe demo:install\nMSG: It broke\n")
  end

  it "prints the Next: block with purposes aligned, bare steps as written, then notes" do
    block = printed do |io|
      Toolkit.next_steps(io, [{"frappe migrate", "apply the new schema"},
                              {"frappe routes", "list the generated URLs"},
                              {"Open /books.", ""}], ["A note."])
    end
    block.should eq(<<-TEXT)

      Next:
        frappe migrate  apply the new schema
        frappe routes   list the generated URLs
        Open /books.

      A note.\n
      TEXT
  end

  it "puts a require line after require \"caramel\", once" do
    required = Toolkit.required(CONFIG, %(require "./demo"))
    required.should start_with(%(require "caramel"\nrequire "./demo"\nrequire "caramel/crema))
    required.lines.size.should eq(CONFIG.lines.size + 1)
    Toolkit.required(required, %(require "./demo")).should eq(required)
  end

  it "refuses to place a require line without exactly one require \"caramel\"" do
    message = %(config/application.cr needs exactly one require "caramel"; ) +
              %(add require "./demo" after it by hand)
    [CONFIG.lchop(%(require "caramel"\n)), CONFIG + %(require "caramel"\n)].each do |config|
      expect_raises(Caramel::Frappe::Error, message) do
        Toolkit.required(config, %(require "./demo"))
      end
    end
  end

  it "writes new files and replaces the files it was given the originals of" do
    project do |root|
      wired = Toolkit.required(CONFIG, %(require "./demo"))
      written = {"config/demo.cr" => "Demo.configure\n", Toolkit::CONFIG => wired}
      Toolkit.publish(root, written, {Toolkit::CONFIG => CONFIG})
      files(root).should eq(written)
    end
  end

  it "refuses to overwrite a file that exists, and writes nothing" do
    project do |root|
      File.write(File.join(root, "config/demo.cr"), "mine\n")
      before = files(root)
      written = {"config/notes.cr" => "new\n", "config/demo.cr" => "theirs\n"}
      message = "File already exists: config/demo.cr; source was preserved"
      expect_raises(Caramel::Frappe::Error, message) { Toolkit.publish(root, written) }
      files(root).should eq(before)
    end
  end

  it "refuses to replace a file that changed since it was planned" do
    project do |root|
      stale = CONFIG + "# an older copy\n"
      written = {Toolkit::CONFIG => "replaced\n", "config/demo.cr" => "new\n"}
      message = "Source changed while planning generation: config/application.cr"
      expect_raises(Caramel::Frappe::Error, message) do
        Toolkit.publish(root, written, {Toolkit::CONFIG => stale})
      end
      files(root).should eq({Toolkit::CONFIG => CONFIG})
    end
  end

  it "undoes its own writes when a later one fails" do
    project do |root|
      File.write(File.join(root, "notes"), "a file where a directory is needed\n")
      before = files(root)
      written = {
        Toolkit::CONFIG  => "replaced\n",
        "config/demo.cr" => "new\n",
        "notes/first.cr" => "unwritable\n",
      }
      expect_raises(File::Error) { Toolkit.publish(root, written, {Toolkit::CONFIG => CONFIG}) }
      files(root).should eq(before)
    end
  end

  it "refuses a path through a symlink" do
    project do |root|
      File.symlink(File.join(root, "config"), File.join(root, "linked"))
      message = "Generator refuses symlinked paths: linked/demo.cr"
      expect_raises(Caramel::Frappe::Error, message) do
        Toolkit.publish(root, {"linked/demo.cr" => "new\n"})
      end
      File.exists?(File.join(root, "config/demo.cr")).should be_false
    end
  end
end
