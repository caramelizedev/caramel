require "caramel/frappe/toolkit"

# The demo shard's tool program: Frappé builds it once and runs it for the commands
# that frappe.yml declares with run: tool. It requires the toolkit alone, not the shard,
# so it builds in an application that does not require the shard yet.
module Demo::Tool
  alias Kit = Caramel::Frappe::Toolkit

  COMMAND     = "demo:install"
  INITIALIZER = "config/demo.cr"
  REQUIRE     = %(require "./demo")

  # Runs the command that *arguments* name, as Frappé hands them over: its words as
  # frappe.yml writes them, then its arguments.
  def self.run(arguments : Array(String)) : Int32
    words = arguments.reject(&.starts_with?("--"))
    return install(words[1]) if words.size == 2 && words.first == "install"
    Kit.failed(STDERR, COMMAND, "unknown command #{words.join(' ')}", agent: Kit.agent?)
    2
  end

  # `demo:install NOTE`: writes the initializer that requires the shard and adds NOTE to
  # its notes, and requires it in config/application.cr.
  def self.install(note : String) : Int32
    root = Kit.root
    config = File.read(File.join(root, Kit::CONFIG))
    files = {INITIALIZER => initializer(note)}
    originals = {} of String => String
    required = Kit.required(config, REQUIRE)
    unless required == config
      files[Kit::CONFIG] = required
      originals[Kit::CONFIG] = config
    end
    Kit.publish(root, files, originals)
    report(files.keys.sort!)
    0
  rescue ex : Caramel::Frappe::Error | File::Error
    Kit.failed(STDERR, COMMAND, ex.message.to_s, agent: Kit.agent?)
    1
  end

  # Says what was written: to an agent with the line that closes a success, to a person
  # with what to run next.
  private def self.report(files : Array(String)) : Nil
    Kit.generated(STDOUT, files)
    if Kit.agent?
      Caramel::Frappe::MRDP.ok(STDOUT, COMMAND, "#{files.size} files")
    else
      Kit.next_steps(STDOUT, [{"frappe demo:notes list", "list the notes, with yours"}])
    end
  end

  private def self.initializer(note : String) : String
    <<-CRYSTAL
      require "demo"

      # This application's note, which frappe demo:notes list prints after the shard's.
      Demo::NOTES << #{note.inspect}

      CRYSTAL
  end
end

exit Demo::Tool.run(ARGV)
