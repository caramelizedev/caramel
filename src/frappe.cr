require "./frappe/cli"
require "./frappe/dev_child"

if ARGV.first? == "__caramel_dev_child"
  exit Caramel::Frappe::DevChild.run(ARGV[1..])
end

executable = Process.executable_path || abort("Cannot locate the Frappé installation")
root = ENV["CARAMEL_FRAMEWORK_ROOT"]? || File.expand_path("..", File.dirname(executable))
exit Caramel::Frappe::CLI.new(root).run(ARGV)
