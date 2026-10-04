module Caramel::Crema
  alias CommandBlock = Proc(Array(String), Int32)

  @@commands = {} of String => {String, CommandBlock}

  # Adds an application command named by its first word, such as `ops` or `jobs`. The
  # block receives the remaining words and flags and returns the exit status; a later
  # registration of the same name replaces an earlier one. `usage` lists *syntax*.
  def self.command(name : String, syntax : String, &block : Array(String) -> Int32) : Nil
    @@commands[name] = {syntax, block}
  end

  # Runs the command *name* with *arguments*; nil when none is registered, and for `db`
  # when the arguments are not `diagnose`, so other words reach the usage error.
  def self.run_command(name : String, arguments : Array(String)) : Int32?
    entry = @@commands[name]? || return
    return if name == "db" && arguments != ["diagnose"]

    entry[1].call(arguments)
  end

  def self.command_syntaxes : Array(String)
    @@commands.values.map(&.[0])
  end
end
