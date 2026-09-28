require "./frappe/cli"
require "./frappe/dev_child"
require "./frappe/dispatch"

if ARGV.first? == "__caramel_dev_child"
  exit Caramel::Frappe::DevChild.run(ARGV[1..])
end

executable = Process.executable_path || abort("Cannot locate the Frappé installation")
root = ENV["CARAMEL_FRAMEWORK_ROOT"]? || File.expand_path("..", File.dirname(executable))

begin
  target = begin
    Caramel::Frappe::Dispatch.target(ARGV)
  rescue ex : Caramel::Frappe::Dispatch::NotInstalled
    # On a terminal, offer to install the release the project pins; agents
    # and pipes get the command instead (ADR 0016).
    raise ex unless STDIN.tty? && STDOUT.tty?
    STDOUT.print("This project uses Caramel #{ex.release}, which is not installed. Install it now? [y/N] ")
    raise Caramel::Frappe::Error.new("Install it later: frappe installations install #{ex.release}") unless {"y", "yes"}.includes?(STDIN.gets.try(&.strip.downcase))
    installations = Caramel::Frappe::Installations.new
    installed = Caramel::Frappe::Release.new(ex.release, installations).install(Caramel::Frappe::Tools.new(root).toolchain.root)
    Caramel::Frappe::Launchers.new.follow(installations)
    File.join(installed, "bin/frappe")
  end
  if target
    Process.exec(target, ARGV, env: {Caramel::Frappe::Dispatch::ENVIRONMENT_KEY => "1", "CARAMEL_FRAMEWORK_ROOT" => nil})
  end
rescue ex : Caramel::Frappe::Error
  STDERR.puts(ex.message)
  exit 1
end

exit Caramel::Frappe::CLI.new(root).run(ARGV)
