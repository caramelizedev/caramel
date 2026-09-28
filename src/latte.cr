require "./latte/daemon"
require "./latte/trust"

begin
  case ARGV
  when ["daemon"], ["daemon", "--detach"]
    registry = Caramel::Latte::Registry.new
    Caramel::Latte::Daemon.detach(registry.paths) if ARGV[1]? == "--detach"
    Caramel::Latte::Daemon.new(registry, Caramel::Latte::Supervisor.new(registry)).run
  when ["stop"]
    stopped = Caramel::Latte::Daemon.stop(Caramel::Latte::Paths.new)
    puts stopped ? "Latte stopped. Services keep running; frappe services stop stops them." : "Latte is not running."
  when ["trust", "install"], ["trust", "remove"]
    registry = Caramel::Latte::Registry.new
    trust = Caramel::Latte::Trust.new(registry.paths, Caramel::Latte::Proxy.new(registry))
    ARGV[1] == "install" ? trust.install : trust.remove
    puts "Latte certificate trust #{ARGV[1] == "install" ? "installed" : "removed"}."
  when ["--help"], ["help"], [] of String
    puts "Latte — Caramel's local environment"
    puts "Usage: latte daemon [--detach] | stop | trust install | trust remove"
    puts "  daemon            Run Latte in this terminal."
    puts "  daemon --detach   Run Latte in its own session, logging to logs/latte.log. Frappé starts Latte this way when it is not running."
    puts "  stop              Stop the running Latte. Services keep running."
    puts "Start and inspect services from Latte in the menu bar or with Frappé."
  else
    STDERR.puts "Unknown command. Use latte --help."
    exit 2
  end
rescue ex : Caramel::Latte::PublicError | Caramel::Latte::Toolchain::Unavailable
  STDERR.puts ex.message
  exit 1
rescue ex
  STDERR.puts "Latte could not start (#{ex.class}). Check the managed toolchain and private state directory."
  exit 1
end
