require "./frappe/cli"

executable = Process.executable_path || abort("Cannot locate the Frappé installation")
root = ENV["CARAMEL_FRAMEWORK_ROOT"]? || File.expand_path("..", File.dirname(executable))
exit Caramel::Frappe::CLI.new(root).run(ARGV)
