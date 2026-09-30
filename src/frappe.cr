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
    pinned = ex.release
    command = "frappe installations install #{pinned}"
    STDOUT.print("This project uses Caramel #{pinned}, which is not installed. " \
                 "Install it now? [y/N] ")
    accepted = {"y", "yes"}.includes?(STDIN.gets.try(&.strip.downcase))
    raise Caramel::Frappe::Error.new("Install it later: #{command}") unless accepted
    installations = Caramel::Frappe::Installations.new
    release = Caramel::Frappe::Release.new(pinned, installations)
    installed = release.install(Caramel::Frappe::Tools.new(root).toolchain.root)
    Caramel::Frappe::Launchers.new.follow(installations)
    File.join(installed, "bin/frappe")
  end
  if target
    dispatched = Caramel::Frappe::Dispatch::ENVIRONMENT_KEY
    Process.exec(target, ARGV, env: {dispatched => "1", "CARAMEL_FRAMEWORK_ROOT" => nil})
  end
rescue ex : Caramel::Frappe::Error
  STDERR.puts(ex.message)
  exit 1
end

exit Caramel::Frappe::CLI.new(root).run(ARGV)
