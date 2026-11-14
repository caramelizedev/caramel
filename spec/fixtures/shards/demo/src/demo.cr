require "caramel"

# The commands this shard's frappe.yml declares, as the application runs them.
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

  # `demo:notes list` and `demo:notes add TEXT`.
  def self.notes(arguments : Array(String)) : Int32
    case arguments.first?
    when "list" then NOTES.each { |note| puts note }
    when "add"  then puts "Added #{arguments[1]?}."
    else             return 2
    end
    0
  end
end

Caramel::Crema.command("demo:greet", "demo:greet NAME [--loud]") do |arguments|
  Demo.greet(arguments)
end

Caramel::Crema.command("demo:notes", "demo:notes list|add TEXT") do |arguments|
  Demo.notes(arguments)
end
