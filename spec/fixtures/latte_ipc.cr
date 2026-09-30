require "../../src/latte/server"

class FixtureServices < Caramel::Latte::ServiceControl
  def initialize(@registry : Caramel::Latte::Registry)
  end

  def status_json : String
    %({"version":1,"services":{"postgres":{"state":"stopped"},) \
    %("dns":{"state":"stopped"},"proxy":{"state":"stopped"}}})
  end

  def start_services : Nil
  end

  def stop_services : Nil
  end

  def register(name : String, directory : String, suffix : String) : Caramel::Latte::Site
    @registry.register(name, directory, suffix)
  end

  def unregister(id : String) : Bool
    !@registry.unregister(id).nil?
  end

  def set_upstream(id : String, socket : String) : Caramel::Latte::Site
    @registry.set_upstream(id, socket)
  end
end

registry = Caramel::Latte::Registry.new(ARGV[0])
registry.register("bookshelf", ARGV[0])
# scripts/check latte-ipc passes the idle timeout and request deadline, in
# seconds, scaled down from the daemon's.
server = Caramel::Latte::Server.new(
  registry,
  FixtureServices.new(registry),
  idle_timeout: ARGV[1].to_f.seconds,
  request_deadline: ARGV[2].to_f.seconds,
)
Process.on_terminate { server.close }
server.listen
