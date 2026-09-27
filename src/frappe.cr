require "./frappe/cli"
require "./frappe/dev_child"
require "./frappe/dispatch"

if ARGV.first? == "__caramel_dev_child"
  exit Caramel::Frappe::DevChild.run(ARGV[1..])
end

begin
  if target = Caramel::Frappe::Dispatch.target(ARGV)
    Process.exec(target, ARGV, env: {Caramel::Frappe::Dispatch::ENVIRONMENT_KEY => "1", "CARAMEL_FRAMEWORK_ROOT" => nil})
  end
rescue ex : Caramel::Frappe::Error
  STDERR.puts(ex.message)
  exit 1
end

executable = Process.executable_path || abort("Cannot locate the Frappé installation")
root = ENV["CARAMEL_FRAMEWORK_ROOT"]? || File.expand_path("..", File.dirname(executable))
exit Caramel::Frappe::CLI.new(root).run(ARGV)
