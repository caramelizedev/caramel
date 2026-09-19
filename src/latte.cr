require "./latte/daemon"
require "./latte/trust"

begin
  case ARGV
  when ["daemon"]
    registry = Caramel::Latte::Registry.new
    Caramel::Latte::Daemon.new(registry, Caramel::Latte::Supervisor.new(registry)).run
  when ["trust", "install"], ["trust", "remove"]
    registry = Caramel::Latte::Registry.new
    trust = Caramel::Latte::Trust.new(registry.paths, Caramel::Latte::Proxy.new(registry))
    ARGV[1] == "install" ? trust.install : trust.remove
    puts "Latte certificate trust #{ARGV[1] == "install" ? "installed" : "removed"}."
  when ["--help"], ["help"], [] of String
    puts "Latte — Caramel's local environment"
    puts "Usage: latte daemon | trust install | trust remove"
    puts "Start and inspect services from Latte in the menu bar or with Frappé."
  else
    STDERR.puts "Unknown command. Use latte --help."
    exit 2
  end
rescue ex : Caramel::Latte::PublicError
  STDERR.puts ex.message
  exit 1
rescue ex
  STDERR.puts "Latte could not start (#{ex.class}). Check the managed toolchain and private state directory."
  exit 1
end
