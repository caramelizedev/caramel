require "spec"
require "file_utils"
require "../../src/frappe/completion"

# What bash offers for the words, the last being the one under the cursor.
private def offered(script : String, words : Array(String), chdir : String? = nil) : Array(String)
  quoted = words.map { |word| "'#{word}'" }.join(' ')
  program = "source #{script}; COMP_WORDS=(#{quoted}); COMP_CWORD=#{words.size - 1}; _frappe; " \
            "printf '%s\\n' \"${COMPREPLY[@]}\""
  output = IO::Memory.new
  arguments = ["--norc", "--noprofile", "-c", program]
  Process.run("bash", arguments, output: output, error: Process::Redirect::Inherit, chdir: chdir)
  output.to_s.lines.reject(&.empty?)
end

describe Caramel::Frappe::Completion do
  script = File.tempname("frappe-completion-", ".bash")
  File.write(script, Caramel::Frappe::Completion.script("bash"))
  Spec.after_suite { File.delete?(script) }

  it "completes commands, subcommands, options and choices" do
    table = Caramel::Frappe::Commands::TABLE
    offered(script, ["frappe", ""]).should eq(table.map(&.words.first).uniq!)
    offered(script, ["frappe", "db", "br"]).should eq(["branch"])
    offered(script, ["frappe", "db", "branch", ""]).should eq(%w[create list delete])
    offered(script, ["frappe", "help", "db", ""]).should eq(%w[dump restore diff branch diagnose])
    offered(script, ["frappe", "make", "resource", "Book", "--pl"]).should eq(["--plural="])
    offered(script, ["frappe", "logs", ""]).should eq(%w[app compiler access --follow])
    offered(script, ["frappe", "make", "resource", "Book", "--plural", "=", ""]).should be_empty
  end

  it "falls back to file names where a command takes a file" do
    directory = File.tempname("frappe-completion-files-")
    Dir.mkdir(directory)
    begin
      File.write(File.join(directory, "backup.dump"), "")
      offered(script, %w[frappe db restore ba], chdir: directory).should eq(["backup.dump"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
