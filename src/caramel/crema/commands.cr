module Caramel::Crema
  alias CommandBlock = Proc(Array(String), Int32)

  @@commands = {} of String => {String, CommandBlock}

  # Adds an application command named by its first word, such as `ops` or `jobs`; a
  # command that a shard declares to Frappé in its frappe.yml is named `shard:name`. The
  # block receives the remaining words and flags and returns the exit status. `usage`
  # lists *syntax*. Raises ArgumentError when *name* is already registered, unless
  # *replace* is true: the recorder takes `insights` over from the stub that says it is off.
  def self.command(name : String,
                   syntax : String,
                   *,
                   replace : Bool = false,
                   &block : Array(String) -> Int32) : Nil
    if @@commands.has_key?(name) && !replace
      raise ArgumentError.new("The command #{name} is already registered")
    end
    @@commands[name] = {syntax, block}
  end

  # Runs the command *name* with *arguments*; nil when none is registered.
  def self.run_command(name : String, arguments : Array(String)) : Int32?
    entry = @@commands[name]? || return
    entry[1].call(arguments)
  end

  def self.command_syntaxes : Array(String)
    @@commands.values.map(&.[0])
  end

  # The name of each registered command, in the order they were added.
  def self.command_names : Array(String)
    @@commands.keys
  end
end
