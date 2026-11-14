require "caramel"

# The commands this shard's frappe.yml declares to run as the application's.
module Demo
  NOTES = ["Water the plants", "Return the books"]

  # `demo:greet NAME [--loud]`: greets NAME, and exits 3 for Nobody.
  def self.greet(arguments : Array(String)) : Int32
    name = arguments.find { |argument| !argument.starts_with?("--") } || return 2
    if name == "Nobody"
      STDERR.puts("Nobody is not a name.")
      return 3
    end
    greeting = "Hello, #{name}!"
    puts arguments.includes?("--loud") ? greeting.upcase : greeting
    0
  end

  # `demo:notes list` and `demo:notes add TEXT`, where - is a line of standard input.
  def self.notes(arguments : Array(String)) : Int32
    case arguments.first?
    when "list" then NOTES.each { |note| puts note }
    when "add"  then return add(arguments[1]?)
    else             return 2
    end
    0
  end

  private def self.add(text : String?) : Int32
    text = STDIN.gets if text == "-"
    return 2 unless text
    puts "Added #{text}."
    0
  end

  # `demo:database`: the name of the database the application connects to.
  def self.database : Int32
    Caramel::CommandLine.with_database(false) do |db, _|
      puts db.scalar("SELECT current_database()")
      0
    end
  end
end

Caramel::Crema.command("demo:greet", "demo:greet NAME [--loud]") do |arguments|
  Demo.greet(arguments)
end

Caramel::Crema.command("demo:notes", "demo:notes list|add TEXT") do |arguments|
  Demo.notes(arguments)
end

Caramel::Crema.command("demo:database", "demo:database") do |_|
  Demo.database
end
