require "../../src/latte/daemon"

registry = Caramel::Latte::Registry.new(ARGV[0])
supervisor = Caramel::Latte::Supervisor.new(
  registry,
  dns_port: ARGV[1].to_i,
  http_port: ARGV[2].to_i,
  https_port: ARGV[3].to_i,
)
begin
  Caramel::Latte::Daemon.new(registry, supervisor).run
ensure
  supervisor.stop_monitor
  supervisor.await_idle(95.seconds)
  supervisor.stop_services
  supervisor.await_idle(65.seconds)
end
